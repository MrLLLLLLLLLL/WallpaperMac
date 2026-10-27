import Foundation

extension URL {
    /// Whether this URL names a directory, based on filesystem metadata.
    ///
    /// `hasDirectoryPath` only inspects the presence of a trailing slash and
    /// misclassifies directory URLs produced by drag-and-drop (no slash).
    /// Use this for any filesystem decision.
    public var isExistingDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
