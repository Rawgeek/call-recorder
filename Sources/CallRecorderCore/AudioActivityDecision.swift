public enum AudioActivityDecision {
    public static func hasExternalInput(
        activeProcessIDs: [Int32],
        ownProcessID: Int32
    ) -> Bool {
        activeProcessIDs.contains { $0 != ownProcessID }
    }
}
