import AppKit
import CruxCore
import SwiftUI

enum DocsetIconMetrics {
    /// Matches the 18-point symbol-type badges used in search navigation.
    static let compact: CGFloat = 18
}

/// One resolution path shared by every place that names a docset.
enum DocsetIconResolver {
    static func image(for descriptor: DocsetDescriptor?, catalogData: Data? = nil) -> NSImage? {
        if let descriptor {
            let root = descriptor.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            for name in [
                "icon@2x.png", "icon@2x.jpg", "icon@2x.jpeg", "icon@2x.gif",
                "icon.png", "icon.jpg", "icon.jpeg", "icon.gif",
            ] {
                let url = descriptor.bundleURL.appending(path: name, directoryHint: .notDirectory)
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/"),
                      let values = try? url.resourceValues(forKeys: [
                          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                      ]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= CatalogEntry.maximumIconBytes,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let validData = CatalogEntry.validatedIconData(data),
                      let image = NSImage(data: validData), image.isValid else {
                    continue
                }
                return image
            }
        }
        if let catalogData,
              let validData = CatalogEntry.validatedIconData(catalogData),
              let image = NSImage(data: validData),
              image.isValid {
            return image
        }
        return descriptor.map { generatedImage(named: $0.displayName) }
    }

    static func generatedImage(named name: String) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let initials = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
        let label = initials.isEmpty ? "?" : initials
        let palette: [NSColor] = [
            .systemBlue, .systemPurple, .systemOrange, .systemTeal,
            .systemPink, .systemGreen, .systemIndigo, .systemBrown,
        ]
        let colorIndex = normalized.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) % palette.count
        }

        return NSImage(size: size, flipped: false) { rect in
            palette[colorIndex].setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 13, yRadius: 13).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: label.count == 1 ? 30 : 24, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let attributed = NSAttributedString(string: label, attributes: attributes)
            let textSize = attributed.size()
            attributed.draw(at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ))
            return true
        }
    }
}

struct DocsetIconView: View {
    let descriptor: DocsetDescriptor?
    var catalogData: Data?
    var fallbackName: String?
    var size: CGFloat = 22

    /// The actual image passed to SwiftUI, also consumed by native menu labels.
    var resolvedImage: NSImage? {
        (DocsetIconResolver.image(for: descriptor, catalogData: catalogData)
            ?? fallbackName.map { DocsetIconResolver.generatedImage(named: $0) })?.withLogicalSize(size)
    }

    var body: some View {
        Group {
            if let image = resolvedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "book.closed.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

private extension NSImage {
    /// Native menu controls extract the underlying image and ignore SwiftUI's
    /// surrounding frame, so the NSImage must carry the intended logical size.
    func withLogicalSize(_ dimension: CGFloat) -> NSImage {
        guard let copy = copy() as? NSImage else { return self }
        copy.size = NSSize(width: dimension, height: dimension)
        return copy
    }
}

/// The canonical icon-and-title presentation for an installed docset.
struct DocsetLabel: View {
    let descriptor: DocsetDescriptor
    var catalogData: Data?
    var iconSize: CGFloat = DocsetIconMetrics.compact
    var displayName: String?
    var sourceName: String?

    var body: some View {
        HStack(spacing: 6) {
            DocsetIconView(
                descriptor: descriptor,
                catalogData: catalogData,
                size: iconSize
            )
            Text(displayName ?? descriptor.displayName)
                .lineLimit(1)
            if let sourceName { Text(sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}
