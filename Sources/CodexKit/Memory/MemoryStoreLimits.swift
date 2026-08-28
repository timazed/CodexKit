import Foundation

/// Hard limits shared by every memory-store implementation.
///
/// These limits keep public inputs, database statements, stored search indexes,
/// and materialized query results predictably bounded across adapters.
public enum MemoryStoreLimits {
    public static let maximumQueryTokenCount = 256
    public static let maximumStoredSearchTokenCount = 2_048
    public static let maximumTokenByteCount = 256
    public static let maximumQueryTextByteCount = 32_768
    public static let maximumSearchableRecordByteCount = 65_536

    public static let maximumQueryResultCount = 256
    public static let maximumListResultCount = 256
    public static let maximumQueryFilterValueCount = 512
    public static let maximumBulkRecordCount = 1_024
    public static let maximumBulkIdentifierCount = 1_024
    public static let maximumBulkCollectionValueCount = 65_536
    public static let maximumBulkSearchTokenCount = 65_536
    public static let maximumBulkEncodedByteCount = 128 * 1_024 * 1_024
    public static let maximumListOffset = 10_000

    public static let maximumIdentifierByteCount = 1_024
    public static let maximumSummaryByteCount = 16_384
    public static let maximumEvidenceCount = 32
    public static let maximumTagCount = 64
    public static let maximumRelatedIDCount = 128
    public static let maximumCollectionValueByteCount = 4_096
    public static let maximumAttributesByteCount = 131_072
    public static let maximumAttributesDepth = 64
    public static let maximumAttributesNodeCount = 10_000

    /// Bounds the work required to materialize complete diagnostics maps.
    public static let maximumDiagnosticDimensionValueCount = 256
}
