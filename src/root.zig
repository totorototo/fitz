const fit = @import("fit.zig");

pub const FitError = fit.FitError;
pub const FileHeader = fit.FileHeader;
pub const RecordHeader = fit.RecordHeader;
pub const NormalRecordHeader = fit.NormalRecordHeader;
pub const CompressedTimestampHeader = fit.CompressedTimestampHeader;
pub const FieldDefinition = fit.FieldDefinition;
pub const DefinitionMessage = fit.DefinitionMessage;
pub const DataMessage = fit.DataMessage;
pub const Record = fit.Record;
pub const Parser = fit.Parser;

test {
    _ = fit;
}
