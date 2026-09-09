// Minimal ABI declarations for the public Horos 4 SDK installed with Horos.
// Implementations are supplied by the host application; no Horos code is bundled.
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>

@interface PluginFilter : NSObject { id viewerController; }
- (void)initPlugin;
- (long)filterImage:(NSString *)menuName;
- (void)willUnload;
@end
@interface DicomDatabase : NSObject
+ (id)defaultDatabase;
+ (id)activeLocalDatabase;
- (NSManagedObjectContext *)managedObjectContext;
@end
@interface BrowserController : NSObject
+ (id)currentBrowser;
- (id)database;
- (NSWindowController *)openViewerFromImages:(NSArray *)images movie:(BOOL)movie viewer:(id)viewer keyImagesOnly:(BOOL)keyImages;
@end
@interface NSManagedObject (RAHorosImage)
- (NSArray *)sortedImages;
- (NSString *)completePath;
- (NSString *)completePathResolved;
- (NSString *)sopInstanceUID;
@end
@interface DCMPix : NSObject
- (id)initWithImageObj:(NSManagedObject *)image;
- (void)CheckLoad;
- (void)checkImageAvailble:(float)width :(float)level;
- (NSImage *)image;
- (long)pwidth;
- (long)pheight;
- (float)ww;
- (float)wl;
- (float)pixelSpacingX;
- (float)pixelSpacingY;
- (BOOL)notAbleToLoadImage;
@end
@interface DCMView : NSView
- (void)scaleToFit;
- (void)setWLWW:(float)level :(float)width;
@end
@interface ViewerController : NSWindowController
- (DCMView *)imageView;
- (void)setOrigin:(NSPoint)origin;
- (void)setImage:(NSManagedObject *)image;
@end
@interface QueryController : NSWindowController
+ (NSArray *)queryStudyInstanceUID:(NSString *)uid server:(NSDictionary *)server showErrors:(BOOL)showErrors;
+ (void)retrieveStudies:(NSArray *)studies showErrors:(BOOL)showErrors;
+ (int)queryAndRetrieveAccessionNumber:(NSString *)accession server:(NSDictionary *)server showErrors:(BOOL)showErrors;
@end
