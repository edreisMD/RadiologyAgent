import Foundation
import CoreGraphics

/// A deliberately bounded preview decoder. Horos remains the full DICOM engine.
/// Supports Part 10, explicit/implicit little endian, single-frame monochrome 8/16-bit.
public struct DICOMImage: Sendable {
    public let rows: Int
    public let columns: Int
    public let pixels: [Double]
    public let monochrome1: Bool
    public let windowCenter: Double
    public let windowWidth: Double
    public let studyUID: String
    public let seriesUID: String
    public let seriesDescription: String
    public let studyDescription: String
    public let modality: String
    public let instanceNumber: Int
    public let patientName: String

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 132, String(bytes: bytes[128..<132], encoding: .ascii) == "DICM" else {
            throw RadError.message("This file is not a Part 10 DICOM. Open it in Horos and open it from the Radiology Agent study library.")
        }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | (Int(bytes[i + 1]) << 8) }
        func u32(_ i: Int) -> Int { u16(i) | (u16(i + 2) << 16) }
        var offset = 132, explicit = true
        var tags: [UInt32: Data] = [:]
        let longVR: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UR", "UT", "UN", "SV", "UV"]
        var count = 0
        while offset + 8 <= bytes.count {
            count += 1
            guard count < 100_000 else { throw RadError.message("DICOM element limit exceeded.") }
            let group = u16(offset), element = u16(offset + 2)
            let tag = UInt32(group << 16 | element)
            let vr = String(bytes: bytes[(offset + 4)..<(offset + 6)], encoding: .ascii) ?? ""
            var header = 8, length: Int
            if group == 2 || explicit {
                guard vr.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { throw RadError.message("Unsupported DICOM encoding. Use Horos for this file.") }
                if longVR.contains(vr) {
                    guard offset + 12 <= bytes.count else { throw RadError.message("Truncated DICOM header.") }
                    header = 12; length = u32(offset + 8)
                } else { length = u16(offset + 6) }
            } else { length = u32(offset + 4) }
            guard length != 0xFFFFFFFF else { throw RadError.message("Encapsulated images or undefined-length sequences require Horos. Open this file there and open it from the Radiology Agent study library.") }
            guard length >= 0, offset + header <= bytes.count, length <= bytes.count - offset - header else { throw RadError.message("The DICOM file is incomplete.") }
            let start = offset + header
            tags[tag] = Data(bytes[start..<(start + length)])
            offset = start + length
            if tag == 0x00020010 {
                let syntax = String(data: tags[tag]!, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
                guard ["1.2.840.10008.1.2", "1.2.840.10008.1.2.1"].contains(syntax) else { throw RadError.message("Compressed or big-endian DICOM: open in Horos, then open it from the Radiology Agent study library.") }
                explicit = syntax != "1.2.840.10008.1.2"
            }
            if tag == 0x7FE00010 { break }
        }
        func number(_ tag: UInt32, default fallback: Int = 0) -> Int {
            guard let value = tags[tag], value.count >= 2 else { return fallback }
            return Int(value[value.startIndex]) | (Int(value[value.startIndex + 1]) << 8)
        }
        func string(_ tag: UInt32) -> String { tags[tag].flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? "" }
        func decimal(_ tag: UInt32, default fallback: Double) -> Double { Double(string(tag).components(separatedBy: "\\").first ?? "") ?? fallback }
        rows = number(0x00280010); columns = number(0x00280011)
        let bits = number(0x00280100), stored = number(0x00280101, default: bits), high = number(0x00280102, default: stored - 1)
        let signed = number(0x00280103) == 1
        let photometric = string(0x00280004)
        guard rows > 0, columns > 0, rows <= 8192, columns <= 8192, rows * columns <= 32_000_000,
              [8, 16].contains(bits), stored > 0, stored <= bits, high == stored - 1,
              number(0x00280002, default: 1) == 1, ["MONOCHROME1", "MONOCHROME2"].contains(photometric) else {
            throw RadError.message("This DICOM pixel layout needs Horos. The integrated preview supports single-frame 8/16-bit monochrome images.")
        }
        guard Int(string(0x00280008)) ?? 1 == 1 else { throw RadError.message("Multiframe DICOM requires Horos. Open it from the Radiology Agent study library to access its native frames.") }
        guard let pixelData = tags[0x7FE00010], pixelData.count >= rows * columns * (bits / 8) else { throw RadError.message("DICOM pixel data is missing or truncated.") }
        let raw = [UInt8](pixelData), slope = decimal(0x00281053, default: 1), intercept = decimal(0x00281052, default: 0)
        guard slope.isFinite, intercept.isFinite else { throw RadError.message("Invalid DICOM rescale values.") }
        let mask = (1 << stored) - 1, signBit = 1 << (stored - 1)
        pixels = (0..<(rows * columns)).map { i in
            var value = (bits == 8 ? Int(raw[i]) : Int(raw[i * 2]) | (Int(raw[i * 2 + 1]) << 8)) & mask
            if signed && value & signBit != 0 { value -= (1 << stored) }
            return Double(value) * slope + intercept
        }
        monochrome1 = photometric == "MONOCHROME1"
        let minimum = pixels.min() ?? 0, maximum = pixels.max() ?? 255
        let wc = decimal(0x00281050, default: (minimum + maximum) / 2)
        let ww = decimal(0x00281051, default: max(1, maximum - minimum))
        windowCenter = wc.isFinite ? wc : 0; windowWidth = ww.isFinite ? max(1, ww) : 256
        studyUID = string(0x0020000D); seriesUID = string(0x0020000E)
        seriesDescription = string(0x0008103E); studyDescription = string(0x00081030)
        modality = string(0x00080060); instanceNumber = Int(string(0x00200013)) ?? 0
        patientName = string(0x00100010).replacingOccurrences(of: "^", with: " ")
    }

    public func grayscale(center: Double? = nil, width: Double? = nil) -> [UInt8] {
        let c = center ?? windowCenter, w = max(1, width ?? windowWidth)
        return pixels.map { p in
            let normalized = w <= 1 ? (p > c - 0.5 ? 1.0 : 0.0) : min(1, max(0, (p - (c - 0.5)) / (w - 1) + 0.5))
            return UInt8((monochrome1 ? 1 - normalized : normalized) * 255)
        }
    }
    public func rendered(center: Double? = nil, width: Double? = nil) -> CGImage? {
        let data = Data(grayscale(center: center, width: width))
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
