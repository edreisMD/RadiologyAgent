#import "HorosAPI.h"
#import <Security/Security.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

static NSString *RAString(NSManagedObject *object, NSString *key) {
    id value = [object valueForKey:key]; return value && value != NSNull.null ? [value description] : @"";
}
static NSString *RAID(NSManagedObject *object) { return object.objectID.URIRepresentation.absoluteString; }
static NSDictionary *RAError(NSString *message) { return @{@"error": message ?: @"Engine error"}; }

@interface RadAgentEngine : PluginFilter
@property(nonatomic) int serverSocket;
@property(nonatomic, copy) NSString *token;
@property(nonatomic) dispatch_queue_t serverQueue;
@property(nonatomic) dispatch_queue_t requestQueue;
@property(nonatomic) dispatch_semaphore_t pendingRequests;
@property(nonatomic) NSCache *pixelCache;
@property(nonatomic) NSMapTable<NSString *, ViewerController *> *seriesViewers;
@end

@implementation RadAgentEngine
- (void)initPlugin { [self startServer]; }
- (long)filterImage:(NSString *)menuName { [self startServer]; return 0; }
- (BOOL)isCertifiedForMedicalImaging { return NO; }
- (void)willUnload { if (self.serverSocket > 0) { close(self.serverSocket); self.serverSocket = -1; } }

- (void)startServer {
    if (self.serverSocket > 0) return;
    self.pixelCache = [NSCache new]; self.pixelCache.countLimit = 6; self.pixelCache.totalCostLimit = 128 * 1024 * 1024;
    self.seriesViewers = [NSMapTable strongToWeakObjectsMapTable];
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/RadAgent"];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) { NSLog(@"RadAgent: cannot prepare engine connection"); return; }
    unsigned char random[32]; if (SecRandomCopyBytes(kSecRandomDefault, sizeof(random), random) != errSecSuccess) return;
    self.token = [[NSData dataWithBytes:random length:sizeof(random)] base64EncodedStringWithOptions:0];
    int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) return;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address = {0}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 8) != 0) { close(fd); return; }
    socklen_t addressLength = sizeof(address); getsockname(fd, (struct sockaddr *)&address, &addressLength);
    self.serverSocket = fd;
    NSDictionary *connection = @{@"port": @(ntohs(address.sin_port)), @"token": self.token, @"protocolVersion": @1, @"pid": @([[NSProcessInfo processInfo] processIdentifier])};
    NSData *data = [NSJSONSerialization dataWithJSONObject:connection options:0 error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"engine-connection.json"];
    // The directory is private, and the atomic replacement is explicitly mode 0600.
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) { close(fd); self.serverSocket = -1; return; }
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
    self.serverQueue = dispatch_queue_create("ai.radiologyagent.engine.accept", DISPATCH_QUEUE_SERIAL);
    self.requestQueue = dispatch_queue_create("ai.radiologyagent.engine.requests", DISPATCH_QUEUE_SERIAL);
    self.pendingRequests = dispatch_semaphore_create(8);
    dispatch_async(self.serverQueue, ^{
        while (self.serverSocket == fd) {
            int client = accept(fd, NULL, NULL); if (client < 0) break;
            if (dispatch_semaphore_wait(self.pendingRequests, DISPATCH_TIME_NOW) != 0) { close(client); continue; }
            dispatch_async(self.requestQueue, ^{ @autoreleasepool { @try { [self handleClient:client]; } @finally { close(client); dispatch_semaphore_signal(self.pendingRequests); } } });
        }
    });
    NSLog(@"RadAgent engine ready on loopback");
}

- (void)handleClient:(int)client {
    struct timeval timeout = {8, 0}; setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int yes = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    NSMutableData *data = [NSMutableData new]; char buffer[4096]; NSRange boundary = NSMakeRange(NSNotFound, 0);
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (data.length < 65536) {
        ssize_t n = recv(client, buffer, sizeof(buffer), 0); if (n <= 0) return;
        [data appendBytes:buffer length:(NSUInteger)n]; boundary = [data rangeOfData:separator options:0 range:NSMakeRange(0, data.length)];
        if (boundary.location != NSNotFound) break;
    }
    if (boundary.location == NSNotFound) return;
    NSString *headers = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, boundary.location)] encoding:NSUTF8StringEncoding];
    NSArray *lines = [headers componentsSeparatedByString:@"\r\n"]; NSArray *request = [[lines firstObject] componentsSeparatedByString:@" "];
    NSMutableDictionary *fields = [NSMutableDictionary new];
    for (NSString *line in lines) { NSRange r = [line rangeOfString:@":"]; if (r.location != NSNotFound) fields[[[line substringToIndex:r.location] lowercaseString]] = [[line substringFromIndex:r.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; }
    if (![fields[@"authorization"] isEqualToString:[@"Bearer " stringByAppendingString:self.token]]) { [self respond:RAError(@"Unauthorized") status:401 client:client]; return; }
    // Browser-origin calls are never accepted, even if a token is somehow copied into a page.
    if (fields[@"origin"] || request.count < 2 || ![request[0] isEqualToString:@"POST"]) { [self respond:RAError(@"POST from native client required") status:403 client:client]; return; }
    NSInteger length = [fields[@"content-length"] integerValue];
    if (length < 2 || length > 32768) { [self respond:RAError(@"Invalid body size") status:400 client:client]; return; }
    NSUInteger start = boundary.location + 4;
    while (data.length < start + length) { ssize_t n = recv(client, buffer, sizeof(buffer), 0); if (n <= 0) return; [data appendBytes:buffer length:(NSUInteger)n]; }
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(start, length)] options:0 error:nil];
    if (![body isKindOfClass:NSDictionary.class]) { [self respond:RAError(@"Invalid JSON object") status:400 client:client]; return; }
    NSString *route = request[1]; __block NSDictionary *result;
    @try {
        if ([route isEqualToString:@"/pacs/retrieve"]) { result = [self retrieve:body]; }
        else {
            // Horos's primary Core Data context and image objects belong to its main thread.
            dispatch_sync(dispatch_get_main_queue(), ^{ @try { result = [self execute:route body:body]; } @catch (NSException *exception) { result = RAError([NSString stringWithFormat:@"Horos could not complete %@ (%@)", route, exception.name]); } });
        }
    } @catch (NSException *exception) { result = RAError([NSString stringWithFormat:@"Horos engine exception (%@)", exception.name]); }
    [self respond:result ?: RAError(@"Empty engine response") status:result[@"error"] ? 422 : 200 client:client];
}
- (void)respond:(NSDictionary *)object status:(int)status client:(int)client {
    NSData *body = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", status, status == 200 ? @"OK" : @"Error", (unsigned long)body.length];
    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]; [response appendData:body];
    const char *bytes = response.bytes; NSUInteger sent = 0;
    while (sent < response.length) { ssize_t n = send(client, bytes + sent, response.length - sent, 0); if (n <= 0) break; sent += (NSUInteger)n; }
}
- (id)database {
    id database = [[NSClassFromString(@"BrowserController") currentBrowser] database];
    return database ?: [NSClassFromString(@"DicomDatabase") defaultDatabase];
}
- (NSManagedObject *)object:(NSString *)uri entity:(NSString *)entity context:(NSManagedObjectContext *)context {
    if (![uri isKindOfClass:NSString.class]) return nil;
    NSURL *url = [NSURL URLWithString:uri]; if (!url || ![url.scheme isEqualToString:@"x-coredata"]) return nil;
    NSManagedObjectID *objectID = [context.persistentStoreCoordinator managedObjectIDForURIRepresentation:url];
    if (!objectID || ![objectID.entity.name isEqualToString:entity]) return nil;
    return [context existingObjectWithID:objectID error:nil];
}
- (NSDictionary *)studyInfo:(NSManagedObject *)study {
    NSDate *date = [study valueForKey:@"date"];
    return @{@"id": RAID(study), @"studyUID": RAString(study, @"studyInstanceUID"), @"patientName": RAString(study, @"name"), @"patientID": RAString(study, @"patientID"), @"title": RAString(study, @"studyName"), @"modality": RAString(study, @"modality"), @"date": date ? @([date timeIntervalSince1970]) : @0, @"imageCount": [study valueForKey:@"numberOfImages"] ?: @0, @"accession": RAString(study, @"accessionNumber")};
}
- (NSDictionary *)execute:(NSString *)route body:(NSDictionary *)body {
    id database = [self database]; NSManagedObjectContext *context = [database managedObjectContext];
    if ([route isEqualToString:@"/health"]) return @{@"engine": @"Horos", @"version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"", @"protocolVersion": @1, @"databaseReady": @(context != nil), @"capabilities": @[@"studies", @"series", @"frames", @"dicom-render", @"dicom-original", @"window-level", @"pacs-retrieve"]};
    if (!context) return RAError(@"Horos database is still opening.");
    if ([route isEqualToString:@"/studies"]) {
        NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Study"];
        NSString *search = [body[@"search"] isKindOfClass:NSString.class] ? body[@"search"] : @"";
        if (search.length) fetch.predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@ OR patientID CONTAINS[cd] %@ OR studyName CONTAINS[cd] %@ OR accessionNumber CONTAINS[cd] %@", search, search, search, search];
        fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"date" ascending:NO]];
        fetch.fetchLimit = MIN(200, MAX(1, [body[@"limit"] integerValue] ?: 100)); fetch.fetchOffset = MAX(0, [body[@"offset"] integerValue]);
        NSError *error = nil; NSArray *studies = [context executeFetchRequest:fetch error:&error]; if (!studies) return RAError(@"Could not query Horos database.");
        NSMutableArray *result = [NSMutableArray new]; for (NSManagedObject *study in studies) [result addObject:[self studyInfo:study]];
        return @{@"studies": result, @"hasMore": studies.count == fetch.fetchLimit ? @YES : @NO};
    }
    if ([route isEqualToString:@"/study"]) {
        NSManagedObject *study = [self object:body[@"id"] entity:@"Study" context:context]; if (!study) return RAError(@"Study no longer exists in the active Horos database.");
        NSArray *series = [[[study valueForKey:@"series"] allObjects] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES]]];
        NSMutableArray *result = [NSMutableArray new]; NSUInteger index = 0;
        for (NSManagedObject *item in series) {
            NSArray *images = [item sortedImages]; NSMutableArray *frames = [NSMutableArray new];
            for (NSManagedObject *image in images) {
                [frames addObject:@{@"id": RAID(image), @"sopInstanceUID": [image sopInstanceUID] ?: @"", @"index": @(index++), @"instance": [image valueForKey:@"instanceNumber"] ?: @0, @"frame": [image valueForKey:@"frameID"] ?: @0, @"width": [image valueForKey:@"storedWidth"] ?: @0, @"height": [image valueForKey:@"storedHeight"] ?: @0}];
            }
            [result addObject:@{@"id": RAID(item), @"uid": RAString(item, @"seriesInstanceUID"), @"dicomUID": RAString(item, @"seriesDICOMUID"), @"name": RAString(item, @"name"), @"modality": RAString(item, @"modality"), @"frames": frames}];
        }
        return @{@"study": [self studyInfo:study], @"series": result, @"frameCount": @(index)};
    }
    if ([route isEqualToString:@"/open-series"]) {
        NSManagedObject *series = [self object:body[@"seriesID"] entity:@"Series" context:context];
        if (!series || ![RAID([series valueForKey:@"study"]) isEqualToString:body[@"studyID"]]) return RAError(@"Series does not belong to the selected study.");
        NSArray *images = [series sortedImages]; if (!images.count) return RAError(@"This series has no images.");
        NSManagedObject *targetImage = body[@"imageID"] ? [self object:body[@"imageID"] entity:@"Image" context:context] : nil;
        if (body[@"imageID"] && (!targetImage || ![images containsObject:targetImage])) return RAError(@"Requested frame does not belong to this series.");
        if (body[@"width"] && (!isfinite([body[@"width"] doubleValue]) || [body[@"width"] doubleValue] < 1 || [body[@"width"] doubleValue] > 1000000 || !isfinite([body[@"center"] doubleValue]) || fabs([body[@"center"] doubleValue]) > 1000000)) return RAError(@"Invalid viewer window values.");
        ViewerController *viewer = [self.seriesViewers objectForKey:RAID(series)];
        BOOL newlyOpened = !viewer || !viewer.window.isVisible;
        if (newlyOpened) {
            // Horos expects one image array per series, even when opening a single series.
            viewer = (ViewerController *)[[NSClassFromString(@"BrowserController") currentBrowser] openViewerFromImages:@[images] movie:NO viewer:nil keyImagesOnly:NO];
        }
        if (!viewer) return RAError(@"Horos could not open this series.");
        [self.seriesViewers setObject:viewer forKey:RAID(series)];
        [viewer showWindow:nil];
        if (targetImage) [viewer setImage:targetImage];
        if (body[@"width"] && body[@"center"]) [[viewer imageView] setWLWW:[body[@"center"] floatValue] :[body[@"width"] floatValue]];
        if (newlyOpened) { [viewer setOrigin:NSZeroPoint]; [[viewer imageView] scaleToFit]; }
        [viewer.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        return @{@"status": @"opened", @"seriesID": RAID(series), @"studyID": body[@"studyID"], @"imageID": targetImage ? RAID(targetImage) : RAID(images.firstObject)};
    }
    if ([route isEqualToString:@"/dicom"]) {
        NSManagedObject *image = [self object:body[@"imageID"] entity:@"Image" context:context];
        if (!image || ![RAID([[image valueForKey:@"series"] valueForKey:@"study"]) isEqualToString:body[@"studyID"]]) return RAError(@"DICOM instance does not belong to the selected study.");
        NSString *path = [image completePathResolved];
        if (!path.length) return RAError(@"Original DICOM file is unavailable.");
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attributes fileSize];
        if (size == 0 || size > 64 * 1024 * 1024) return RAError(@"Original DICOM instance is unavailable or exceeds the 64 MB transfer limit.");
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (!data) return RAError(@"Could not read the original DICOM instance.");
        return @{@"dicom": [data base64EncodedStringWithOptions:0], @"imageID": RAID(image), @"sopInstanceUID": [image sopInstanceUID] ?: @"", @"bytes": @(data.length)};
    }
    if ([route isEqualToString:@"/render"]) {
        NSManagedObject *image = [self object:body[@"imageID"] entity:@"Image" context:context]; if (!image) return RAError(@"DICOM frame no longer exists.");
        NSManagedObject *study = [[image valueForKey:@"series"] valueForKey:@"study"];
        if (![RAID(study) isEqualToString:body[@"studyID"]]) return RAError(@"Frame does not belong to the selected study.");
        NSString *imageID = RAID(image); NSDictionary *cached = [self.pixelCache objectForKey:imageID]; DCMPix *pix = cached[@"pix"];
        if (!pix) {
            pix = [[NSClassFromString(@"DCMPix") alloc] initWithImageObj:image]; [pix CheckLoad];
            if (!pix || pix.notAbleToLoadImage) return RAError(@"Horos could not decode this DICOM frame.");
            [pix checkImageAvailble:pix.ww :pix.wl];
            cached = @{@"pix": pix, @"defaultWidth": @(pix.ww), @"defaultCenter": @(pix.wl)};
            [self.pixelCache setObject:cached forKey:imageID cost:(NSUInteger)MAX(0, pix.pwidth) * (NSUInteger)MAX(0, pix.pheight) * 8];
        }
        float width = body[@"width"] ? [body[@"width"] floatValue] : [cached[@"defaultWidth"] floatValue];
        float center = body[@"center"] ? [body[@"center"] floatValue] : [cached[@"defaultCenter"] floatValue];
        if (!isfinite(width) || !isfinite(center) || width < 0 || width > 1000000 || fabs(center) > 1000000) return RAError(@"Invalid window values.");
        [pix checkImageAvailble:width :center];
        NSImage *render = [pix image]; if (!render) return RAError(@"Horos returned no pixels.");
        NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:[render TIFFRepresentation]];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]; if (!png) return RAError(@"Could not encode rendered DICOM frame.");
        return @{@"png": [png base64EncodedStringWithOptions:0], @"width": @(pix.pwidth), @"height": @(pix.pheight), @"windowWidth": @(pix.ww), @"windowCenter": @(pix.wl), @"pixelSpacingX": @(pix.pixelSpacingX), @"pixelSpacingY": @(pix.pixelSpacingY), @"imageID": imageID, @"studyID": RAID(study), @"source": @"Horos DCMPix · native DICOM pixels"};
    }
    if ([route isEqualToString:@"/pacs/nodes"]) {
        NSArray *servers = [[NSUserDefaults standardUserDefaults] arrayForKey:@"SERVERS"] ?: @[]; NSMutableArray *result = [NSMutableArray new];
        for (NSUInteger i = 0; i < servers.count; i++) { NSDictionary *server = servers[i]; if (![server isKindOfClass:NSDictionary.class]) continue; [result addObject:@{@"index": @(i), @"name": server[@"Description"] ?: server[@"AETitle"] ?: @"DICOM node", @"aet": server[@"AETitle"] ?: @"", @"address": server[@"Address"] ?: @"", @"port": [server[@"Port"] description] ?: @""}]; }
        return @{@"nodes": result};
    }
    return RAError(@"Unknown engine action.");
}
- (NSDictionary *)retrieve:(NSDictionary *)body {
    NSArray *servers = [[NSUserDefaults standardUserDefaults] arrayForKey:@"SERVERS"] ?: @[];
    NSInteger index = [body[@"node"] integerValue];
    if (!body[@"node"] || index < 0 || index >= servers.count) return RAError(@"Choose a configured Horos PACS node.");
    NSString *uid = [body[@"studyUID"] isKindOfClass:NSString.class] ? body[@"studyUID"] : @"";
    NSString *accession = [body[@"accession"] isKindOfClass:NSString.class] ? body[@"accession"] : @"";
    if (uid.length) {
        if (uid.length > 64 || [uid rangeOfString:@"^[0-9]+(\\.[0-9]+)*$" options:NSRegularExpressionSearch].location == NSNotFound) return RAError(@"Invalid Study Instance UID.");
        NSArray *studies = [NSClassFromString(@"QueryController") queryStudyInstanceUID:uid server:servers[index] showErrors:NO];
        if (!studies.count) return RAError(@"The PACS returned no matching study, or the DICOM query failed.");
        [NSClassFromString(@"QueryController") retrieveStudies:studies showErrors:NO];
        return @{@"status": @"requested", @"matches": @(studies.count), @"message": @"Retrieval requested through Horos. Refresh the study library to see received instances; receipt is not yet confirmed."};
    }
    if (accession.length > 0 && accession.length <= 128) {
        int status = [NSClassFromString(@"QueryController") queryAndRetrieveAccessionNumber:accession server:servers[index] showErrors:NO];
        return @{@"status": @"requested", @"horosStatus": @(status), @"message": @"Query/retrieve requested through Horos. Refresh the library to verify receipt."};
    }
    return RAError(@"Enter a Study Instance UID or accession number.");
}
@end
