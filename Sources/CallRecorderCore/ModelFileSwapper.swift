import Foundation

/// Moves model files in and out of place without ever leaving the user with nothing.
///
/// Each step is a rename inside one directory, which the file system performs atomically. The
/// file being replaced is moved aside first and only removed once the new one is in position, so
/// an interrupted update or a failed move still leaves a working model behind.
public enum ModelFileSwapper {
    /// Puts a verified file at its destination, keeping the file it replaces.
    ///
    /// - Returns: true when a previous copy was kept, which is what makes a revert possible.
    @discardableResult
    public static func swapIn(verified: URL, destination: URL, previous: URL) throws -> Bool {
        let manager = FileManager.default
        let hadExisting = manager.fileExists(atPath: destination.path)
        if hadExisting {
            // Only one earlier copy is kept. Keeping a chain would grow without limit, and the
            // copy from before the last update is the one a person would want back.
            try? manager.removeItem(at: previous)
            try manager.moveItem(at: destination, to: previous)
        }
        do {
            try manager.moveItem(at: verified, to: destination)
        } catch {
            if hadExisting {
                try? manager.moveItem(at: previous, to: destination)
            }
            throw error
        }
        return hadExisting
    }

    /// Puts the kept copy back and forgets it.
    public static func revert(destination: URL, previous: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: previous.path) else {
            throw ModelUpdateError.noEarlierCopy
        }
        // Stage the current file rather than deleting it, so a failure mid-revert can be undone.
        let staging = destination.appendingPathExtension("reverting")
        try? manager.removeItem(at: staging)
        let hadCurrent = manager.fileExists(atPath: destination.path)
        if hadCurrent {
            try manager.moveItem(at: destination, to: staging)
        }
        do {
            try manager.moveItem(at: previous, to: destination)
        } catch {
            if hadCurrent { try? manager.moveItem(at: staging, to: destination) }
            throw error
        }
        try? manager.removeItem(at: staging)
    }

    /// Removes both the model and the copy kept from the last update.
    public static func remove(destination: URL, previous: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: previous)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
    }
}

public enum ModelUpdateError: LocalizedError, Equatable {
    case noEarlierCopy

    public var errorDescription: String? {
        switch self {
        case .noEarlierCopy: "There is no earlier copy of this model to go back to."
        }
    }
}
