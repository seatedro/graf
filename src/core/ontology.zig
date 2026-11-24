const std = @import("std");
const types = @import("types.zig");

pub const CoreRelation = struct {
    name: []const u8,
    cardinality: types.Cardinality,
    opposes: ?[]const u8 = null,
    object_kind: types.ObjectKind = .either,
    description: []const u8,
};

pub const core_relations = [_]CoreRelation{
    .{ .name = "uses", .cardinality = .many, .description = "Subject uses the object (a tool, library, service, or technique)." },
    .{ .name = "depends_on", .cardinality = .many, .object_kind = .entity, .description = "Subject requires the object to build or run." },
    .{ .name = "chose", .cardinality = .many, .opposes = "rejected", .description = "Subject decided in favor of the object." },
    .{ .name = "rejected", .cardinality = .many, .opposes = "chose", .description = "Subject decided against the object." },
    .{ .name = "supports_feature", .cardinality = .many, .opposes = "lacks_feature", .description = "Subject has the named capability." },
    .{ .name = "lacks_feature", .cardinality = .many, .opposes = "supports_feature", .description = "Subject does not have the named capability." },
    .{ .name = "prefers", .cardinality = .many, .opposes = "avoids", .description = "Subject prefers the object." },
    .{ .name = "avoids", .cardinality = .many, .opposes = "prefers", .description = "Subject avoids the object." },
    .{ .name = "works_on", .cardinality = .many, .object_kind = .entity, .description = "Person or team works on the object." },
    .{ .name = "member_of", .cardinality = .many, .object_kind = .entity, .description = "Subject is a member of the object group." },
    .{ .name = "maintains", .cardinality = .many, .object_kind = .entity, .description = "Subject maintains the object." },
    .{ .name = "part_of", .cardinality = .many, .object_kind = .entity, .description = "Subject is a component of the object." },
    .{ .name = "has_setting", .cardinality = .one_per_subject_qualifier, .object_kind = .value, .description = "Subject's setting named by the qualifier has this value." },
    .{ .name = "has_status", .cardinality = .one_per_subject, .object_kind = .value, .description = "Subject's current status." },
    .{ .name = "has_version", .cardinality = .one_per_subject, .object_kind = .value, .description = "Subject's current version." },
    .{ .name = "located_at", .cardinality = .one_per_subject, .description = "Subject's current location or host." },
    .{ .name = "has_oncall", .cardinality = .one_per_subject, .object_kind = .entity, .description = "Who is currently on call for the subject." },
    .{ .name = "owned_by", .cardinality = .one_per_subject, .object_kind = .entity, .description = "Current owner of the subject." },
    .{ .name = "scheduled_for", .cardinality = .one_per_subject, .object_kind = .value, .description = "When the subject is scheduled to happen." },
    .{ .name = "blocked_by", .cardinality = .many, .description = "Subject cannot proceed until the object is resolved." },
    .{ .name = "caused_by", .cardinality = .many, .description = "Subject was caused by the object." },
    .{ .name = "fixed_by", .cardinality = .many, .description = "Subject was fixed by the object." },
    .{ .name = "related_to", .cardinality = .many, .description = "Fallback when no other relation fits. Avoid." },
};

pub fn find(name: []const u8) ?*const CoreRelation {
    for (&core_relations) |*relation| if (std.mem.eql(u8, relation.name, name)) return relation;
    return null;
}

test "opposed relations are symmetric" {
    for (core_relations) |relation| {
        const other_name = relation.opposes orelse continue;
        const other = find(other_name) orelse return error.MissingOpposite;
        try std.testing.expectEqualStrings(relation.name, other.opposes.?);
    }
}
