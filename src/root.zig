const fit = @import("fit.zig");

/// Names, units, scale and offset for well-known messages and fields.
pub const profile = @import("profile.zig");

pub const FitError = fit.FitError;
pub const FileHeader = fit.FileHeader;
pub const RecordHeader = fit.RecordHeader;
pub const NormalRecordHeader = fit.NormalRecordHeader;
pub const CompressedTimestampHeader = fit.CompressedTimestampHeader;
pub const BaseType = fit.BaseType;
pub const FieldDefinition = fit.FieldDefinition;
pub const DefinitionMessage = fit.DefinitionMessage;
pub const DataMessage = fit.DataMessage;
pub const FieldIterator = fit.FieldIterator;
pub const Field = fit.Field;
pub const Value = fit.Value;
pub const Record = fit.Record;
pub const Parser = fit.Parser;

test {
    _ = fit;
    _ = profile;
}
