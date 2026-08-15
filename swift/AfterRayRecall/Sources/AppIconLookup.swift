import AppKit

/// Both halves of an app icon lookup — resolving the bundle id to a URL and
/// reading the icon — go through Launch Services and the disk. Uncached,
/// every rendered timeline segment repeated both on every frame of a scroll.
/// Shared by the timeline segments and the history panel's icon strips.
public enum AppIconLookup {
    private static let cache = NSCache<NSString, NSImage>()
    /// Marks "looked it up, there is no icon", so a missing app does not
    /// re-query Launch Services forever.
    private static let absent = NSImage(size: .zero)

    public static func icon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let key = bundleIdentifier as NSString
        if let cached = cache.object(forKey: key) {
            return cached === absent ? nil : cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            cache.setObject(absent, forKey: key)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
