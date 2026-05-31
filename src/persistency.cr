# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "json"
require "./bidirhash"
require "./constants"
require "./patch"

module Persistency

# general design decisions
# - basic types Nil, String, Bool, Int64 and Float64 (i.e. no Int32)
# - easy key/value storage
# - commit, field and record LIDs as the basic addressing scheme
# - (commit,field,record) -> user-defined value (or nil, when not defined); i.e. setting to "nil" effectively deletes an entry
# - LIDs (local IDs) are locally unique, GIDs (global IDs) globally
# - LIDs are made unique just by consecutively creating the next LID
# - GIDs are made unique by PRNGs and big enough size (e.g. 256b, 32B)
# - every Persistency instance keeps own mapping of LID <-> GID, communication between instances always via GIDs
# - meta fields for handling higher level concepts (e.g. tables); in this concept the record LID often plays the role of a "user" field/table etc.
# - (table or field) names are fully user defined (but need to be Strings), tool works just as well when all are ""
# - user data typically untyped, except reference types; and meta types (e.g. field and table names)
# - higher level methods typically alter meta data only (i.e. #remove_table leaves the physical data untouched; #get_value(field,record) still can retrieve it)
# - there is no digital "delete" operation on a field
#   - i.e. after a (referenced) field is deleted, the referencing table can still move to another referenced field in the same referenced table
#   - i.e. after a referenced table is fully deleted, the user can still revert the referencing field to a value field with a copy of the referenced record values
# - it is forbidden for references to point directly to another reference (assert); would be a problem when retrieving data of removed field; also would mean extra effort for which values to display to the user (shouldn't be a RecordLID)

alias Cell = String|Int64|Float64|Bool|Nil
alias Default = Layer01(Cell) # simple shortcut

private pseudo_enum MetaFieldLIDs, 0i64, -1,
[ # record_lid => value in the respective field has the meaning...
    RootCommit, # special, needs to be 0; includes all the commit predecessors in this very field (vs. Predecessors)
    Predecessors, # valid for Records, Fields, Tables; nil if no predecessor; not used for Commits themselves (Layer00, w/o version control)
    Names, # field_lid or table_lid => GUI name (String)
    TableLastTable, # a pseudo TableLID, its RecordLIDs define a sequence over all tables; only used as a TableLID (not FieldLID or RecordLID)
    TableLastField, # table_lid => last_field_lid
    TableLastRecord, # table_lid => last_record_lid
    RefersTo, # (user) source field_lid => target field_lid (if source is of type "reference")
    BelongsTo, # field_lid or record_lid => table_lid; TODO(persistency): doesn't hold for record_lid with coupled tables
]

# for easier reading
alias FieldLID = Int64
alias RecordLID = Int64
alias CommitLID = Int64
alias TableLID = Int64

# GID_Size = 256 # bit # doesn't do compile-time const prop.
GID_Size = 256 // 8 # works

class Context
    include JSON::Serializable
    @[JSON::Field(ignore: true)]
    @root_commit : CommitLID = MetaFieldLIDs::RootCommit # >= root_commit (inclusive lower bound for net reads)
    @[JSON::Field(ignore: true)]
    @current_commit : CommitLID = MetaFieldLIDs::RootCommit # <= current_commit (inclusive upper bound for net reads)
    @[JSON::Field(ignore: true)]
    @metadata_root_commit : CommitLID = MetaFieldLIDs::RootCommit # lower bound for meta reads (field_lid < 0)
    @[JSON::Field(ignore: true)]
    @metadata_commit : CommitLID = MetaFieldLIDs::RootCommit # upper bound for meta reads; must stay >= current_commit
    @[JSON::Field(ignore: true)]
    getter version = 0
    def initialize
    end
    protected def initialize(other : Context)
        @root_commit = other.@root_commit
        @current_commit = other.@current_commit
        @metadata_root_commit = other.@metadata_root_commit
        @metadata_commit = other.@metadata_commit
    end
    def clone : Context
        Context.new(self)
    end
    def root_commit : CommitLID
        @root_commit
    end
    def root_commit=(commit : CommitLID) : CommitLID
        @version += 1
        @root_commit = commit
    end
    def current_commit : CommitLID
        @current_commit
    end
    def current_commit=(commit : CommitLID) : CommitLID
        @version += 1
        @current_commit = commit
        # Auto-sync metadata_commit to keep existing callers (history navigation,
        # rollback) working — the meta read path should track the net path by
        # default. Callers wanting divergence (e.g. diff-Shape, permission
        # views) set metadata_commit explicitly AFTER current_commit=.
        @metadata_commit = commit
        commit
    end
    def metadata_commit : CommitLID
        @metadata_commit
    end
    def metadata_commit=(commit : CommitLID) : CommitLID
        @version += 1
        @metadata_commit = commit
    end
    def metadata_root_commit : CommitLID
        @metadata_root_commit
    end
    def metadata_root_commit=(commit : CommitLID) : CommitLID
        @version += 1
        @metadata_root_commit = commit
    end
end

# we use a context stack in order to allow simple Persistency access without passing contexts with every method
# if differentiations are needed the user can make use of #push and #pop to temporarily change the current context (and restore it later)
class ContextStack
    @contexts = [Context.new]
    def push(context : Context = top) : Nil
        @contexts << context
    end
    def pop : Context
        @contexts.pop
    end
    def top : Context
        @contexts[-1]
    end
    def top=(context : Context) : Context
        context.root_commit = context.root_commit # trigger version increment
        @contexts[-1] = context
    end
end

# Summary of what's changed in a single commit, grouped per table.
struct TableChanges
    property records_added   : Int32 = 0
    property records_removed : Int32 = 0
    property fields_added    : Int32 = 0
    property fields_removed  : Int32 = 0
    property cells_changed   : Int32 = 0
    def empty? : Bool
        @records_added == 0 && @records_removed == 0 &&
        @fields_added == 0 && @fields_removed == 0 &&
        @cells_changed == 0
    end
end

end # module Persistency

#################################

# this simple API any backend needs to provide
module Interface::Persistency::Backend(T)
    include ::Persistency # bring FieldLID/RecordLID/CommitLID/TableLID aliases into scope (Crystal 1.20+)
    @[JSON::Field(ignore: true)]
    @context_stack = ContextStack.new
    @[JSON::Field(ignore: true)]
    @meta_version = 0
    @[JSON::Field(ignore: true)]
    @version = 0
    abstract def get_value(field_lid : FieldLID, record_lid : RecordLID) : T # attention: caller needs to ensure that record_lid is currently existing!
    abstract def set_value(field_lid : FieldLID, record_lid : RecordLID, value : T)
    abstract def close_and_add_commit : CommitLID
    abstract def transaction(&) : Nil
    abstract def get_special(key : String) : String?
    abstract def set_special(key : String, value : String) : Nil
    protected abstract def get_field_internal(field_lid : FieldLID) : Hash(RecordLID,T) # attention: also potentially deleted record_lid items may get returned
    protected abstract def get_new_lid : Int64
    protected abstract def get_ancestors(start_lid : Int64) : Array(RecordLID) # retrieves all (in)direct predecessors (vs. #get_field)
    def clone
        self.class.new(self)
    end
    def contexts : ContextStack
        @context_stack
    end
    def context : Context
        @context_stack.top
    end
    def context=(context) : Context
        @context_stack.top = context
    end
    def version : Int32
        @version
    end
    def meta_version : Int32
        @meta_version
    end
    # a predefined shorthand (based on #get_ancestors); inefficient, but will be overloaded in higher level
    protected def get_successor(lid : RecordLID, last_lid : RecordLID) : RecordLID?
        if lid == last_lid
            nil # no successor, because it's the last in the list
        else
            records = get_ancestors(last_lid)
            if lid_rank = records.index {|el| el == lid}
                records[lid_rank+1]
            else
                nil # no successor, because it's not in the list at all
            end
        end
    end
end

#################################

# simple Hash-based implementation
# data is free of redundancy, serialization is implemented
# this can still be enhanced by caching techniques (higher layer)
# this can be combined with SQL or Redis to provide real persistency
# introduces the following MetaFieldLIDs: RootCommit, Predecessors
# attention: design decision: meta fields define content (i.e. which records are in use); advantage: un-deleting possible, net values still there
# attention: is not reentrant
class Persistency::Backend::Memory(T)
    include JSON::Serializable # must be included in _root classes/structs_ only!
    include Interface::Persistency::Backend(T)
    @[JSON::Field(key: "x")]
    protected getter field2record2commit2value : Hash(FieldLID,Hash(RecordLID,Hash(CommitLID,T)))
    @[JSON::Field(key: "y")]
    protected getter lid2gid : Array(Array(UInt8))
    @[JSON::Field(key: "z")]
    protected getter special : Hash(String,String)
    def initialize
        @field2record2commit2value = Hash(FieldLID,Hash(RecordLID,Hash(CommitLID,T))).new do |hash,key| # we use this to allow access to unused keys; BTW: Set or Array lack this!
            hash[key] = Hash(RecordLID,Hash(CommitLID,T)).new do |hash,key|
                hash[key] = Hash(CommitLID,T).new
            end
        end
        @lid2gid = Array(Array(UInt8)).new
        @special = Hash(String,String).new
        get_new_lid # reserve lid 0 for root commit
    end
    private def after_initialize # called by Crystal after #from_json; we need to fix Hash default block
        field2record2commit2value = Hash(FieldLID,Hash(RecordLID,Hash(CommitLID,T))).new do |hash,key| # we use this to allow access to unused keys; BTW: Set or Array lack this!
            hash[key] = Hash(RecordLID,Hash(CommitLID,T)).new do |hash,key|
                hash[key] = Hash(CommitLID,T).new
            end
        end
        @field2record2commit2value.each do |k1,v1|
            v1.each do |k2,v2|
                v2.each do |k3,v3|
                    field2record2commit2value[k1][k2][k3] = v3
                end
            end
        end
        @field2record2commit2value = field2record2commit2value
    end
    protected def initialize(other : self) # for cloning
        @context_stack = other.@context_stack.dup
        @field2record2commit2value = other.field2record2commit2value.clone # also copies the default block from above
        @lid2gid = other.lid2gid.clone
        @special = other.special.clone
        # don't forget about those...
        @meta_version = other.@meta_version
        @version = other.@version
    end
    def get_value(field_lid : FieldLID, record_lid : RecordLID) : T # is only correct if the record_lid is really defined!
        commit2rank = path_for_field(field_lid).map_with_index {|c,i| {c,i}}.to_h # rank: the higher, the newer
        commit2value = @field2record2commit2value[field_lid][record_lid]
        commit = (commit2rank.keys & commit2value.keys).max_by? {|el| commit2rank[el]}
        commit ? commit2value[commit] : nil # sparse storage, default is nil
    end
    def set_value(field_lid : FieldLID, record_lid : RecordLID, value : T)
        # we must not do a check if the set is invariant at this low level, because it will disrupt the higher level cache (i.e. #set will internally trigger #get with old data)
        # TODO(meta-writes): today meta-field writes (field_lid < 0) land on context.current_commit
        # like everything else. With the planned permissions-system use of metadata_commit
        # (semantic: metadata_commit >= current_commit; "latest permissions always active"),
        # we may want meta writes to target context.metadata_commit instead. Revisit when
        # permissions / older-schema viewing lands.
        if is_commit_closed? || (context.current_commit==MetaFieldLIDs::RootCommit)
            # -> we need to create another one (that is still open)
            close_and_add_commit
        end
        @field2record2commit2value[field_lid][record_lid][context.current_commit] = value
        @version += 1
        @meta_version += 1 if field_lid < 0
    end
    def close_and_add_commit : CommitLID
        # first version of a "branch"
        lid = get_new_lid
        @field2record2commit2value[MetaFieldLIDs::RootCommit][lid][MetaFieldLIDs::RootCommit] = context.current_commit
        @version += 1
        context.metadata_commit = context.current_commit = lid
    end
    def transaction(&) : Nil # this is a poor man's transaction
        safe_state = clone # BTW: this also clones any subclass instance variables (e.g. Cacher); i.e. it is safe
        begin
            yield
        rescue ex
            self.replace(safe_state)
            raise(ex)
        end
    end
    def get_special(key : String) : String?
        @special[key]?
    end
    def set_special(key : String, value : String) : Nil
        @special[key] = value
    end
    protected def get_new_lid : Int64
        gid = Array(UInt8).new(GID_Size, 0)
        lid = @lid2gid.size.to_i64
        if lid != 0 # special case for lid=0 (root commit)
            (GID_Size).times do |i|
                gid[i] = rand(0x100).to_u8
            end
        end
        @lid2gid << gid
        lid
    end
    protected def get_ancestors(start_lid : Int64) : Array(RecordLID) # retrieves all (in)direct predecessors (vs. #get_field)
        res = Array(RecordLID).new
        # Predecessors is a meta field (field_lid < 0) — use the meta path.
        commit2rank = path_for_field(MetaFieldLIDs::Predecessors).map_with_index {|c,i| {c,i}}.to_h # rank: the higher, the newer
        current_lid = start_lid
        while current_lid.is_a?(RecordLID)
            res << current_lid
            commit2value = @field2record2commit2value[MetaFieldLIDs::Predecessors][current_lid]
            commit = commit2value.keys.max_by? {|el| commit2rank[el]? || -1i64}
            current_lid = (!commit.nil? && commit2rank[commit]?) ? commit2value[commit]? : nil
        end
        res.reverse
    end
    protected def get_field_internal(field_lid : FieldLID) : Hash(RecordLID,T) # retrieves all values of field (also potentially deleted ones, but not from excluded commits!)
        if field_lid == MetaFieldLIDs::RootCommit
            @field2record2commit2value[field_lid].map {|record_lid, commit2value| {record_lid, commit2value.first_value} }.to_h
        else
            commit2rank = path_for_field(field_lid).map_with_index {|c,i| {c,i}}.to_h # rank: the higher, the newer
            record2commit2value = @field2record2commit2value[field_lid]
            record2commit2value.map do |record, commit2value|
                commit = commit2value.keys.max_by? {|el| commit2rank[el]? || -1i64}
                {record, (!commit.nil? && commit2rank[commit]?) ? commit2value[commit]? : nil}
            end.to_h
        end
    end
    # Per-table summary of writes landed on the currently-open commit
    # (= context.current_commit). Returns an empty Hash when no commit is open
    # (freshly-created persistency with context.current_commit == RootCommit).
    #
    # Approach (two passes over @field2record2commit2value):
    #   Pass 1 — cell edits: every non-meta field write with an entry at target
    #            counts as one cells_changed on the owning table.
    #   Pass 2 — adds: every Predecessors[new_lid] entry at target represents a
    #            newly-created LID. Disambiguate record vs field via Names
    #            (fields have a Name, records don't). Route to the owning table
    #            via BelongsTo.
    #
    # TableLastRecord / TableLastField writes can't be counted directly — they
    # are chain-tail pointers that overwrite on each add_record/add_field, so
    # only the latest write is visible at the target commit regardless of how
    # many records/fields were added in that commit.
    def changes_in_open_commit : Hash(TableLID, TableChanges)
        target = context.current_commit
        result = Hash(TableLID, TableChanges).new
        return result if target == MetaFieldLIDs::RootCommit
        # Pass 1: cell edits per owning table
        @field2record2commit2value.each do |field_lid, r2c2v|
            next if field_lid < 0
            r2c2v.each do |record_lid, c2v|
                next unless c2v.has_key?(target)
                belongs = get_value(MetaFieldLIDs::BelongsTo, field_lid)
                next unless belongs.is_a?(Int64)
                table_lid = belongs.as(TableLID)
                next if table_lid < 0
                tc = result[table_lid]? || TableChanges.new
                tc.cells_changed += 1
                result[table_lid] = tc
            end
        end
        # Pass 2: record/field additions via Predecessors entries at target.
        # Predecessors is also rewritten at target as a SIDE EFFECT of
        # removing a neighbour (the successor's predecessor pointer is
        # rebound to skip the deleted lid) — those rewrites must NOT
        # be counted as additions. Distinguish a true "new lid" by
        # requiring BelongsTo[lid] to have its first non-nil write at
        # target (== the lid didn't belong to the table before).
        if predecessors = @field2record2commit2value[MetaFieldLIDs::Predecessors]?
            predecessors.each do |new_lid, c2v|
                next unless c2v.has_key?(target)
                belongs_history = @field2record2commit2value[MetaFieldLIDs::BelongsTo][new_lid]?
                next unless belongs_history
                target_belongs = belongs_history[target]?
                next unless target_belongs.is_a?(Int64)
                # Skip if BelongsTo had any non-nil write at an earlier commit
                # (then this lid pre-existed; the Predecessors entry is a
                # side-effect rewrite, not a creation).
                pre_existed = belongs_history.any? { |c, v| c != target && !v.nil? }
                next if pre_existed
                table_lid = target_belongs.as(TableLID)
                next if table_lid < 0
                name = get_value(MetaFieldLIDs::Names, new_lid.as(FieldLID))
                tc = result[table_lid]? || TableChanges.new
                if name.nil?
                    tc.records_added += 1
                else
                    tc.fields_added += 1
                end
                result[table_lid] = tc
            end
        end
        # Pass 3: record/field removals via BelongsTo[lid] = nil at target.
        # remove_record / remove_field set BelongsTo[lid] to nil at the open
        # commit. The prior non-nil value tells us which table the lid used
        # to belong to (records can't move tables, so any prior non-nil
        # write yields the same TableLID). Records vs fields: fields have a
        # Names entry, records don't.
        @field2record2commit2value[MetaFieldLIDs::BelongsTo].each do |lid, c2v|
            next unless c2v.has_key?(target)
            next unless c2v[target].nil?
            prior_table_lid : TableLID? = nil
            c2v.each do |c, v|
                next if c == target
                next if v.nil?
                next unless v.is_a?(Int64)
                prior_table_lid = v.as(TableLID)
                break  # any prior non-nil write yields the right table
            end
            next unless prior_table_lid
            next if prior_table_lid < 0
            names_c2v = @field2record2commit2value[MetaFieldLIDs::Names][lid]?
            has_name = !!(names_c2v && names_c2v.values.any? { |v| !v.nil? })
            tc = result[prior_table_lid]? || TableChanges.new
            if has_name
                tc.fields_removed += 1
            else
                tc.records_removed += 1
            end
            result[prior_table_lid] = tc
        end
        result
    end

    # All (user-field, record) pairs whose cells were written at `commit`.
    # Meta-field writes (field_lid < 0) are skipped — this is the data-cell
    # diff, not the schema-change diff.
    #
    # O(F·R) scan, memoized by {version, commit} to keep GUI render loops
    # from rescanning every frame.
    @[JSON::Field(ignore: true)]
    @cells_written_cache : Hash({Int32, CommitLID}, Set({FieldLID, RecordLID})) = Hash({Int32, CommitLID}, Set({FieldLID, RecordLID})).new
    def cells_written_at(commit : CommitLID) : Set({FieldLID, RecordLID})
        key = {@version, commit}
        cached = @cells_written_cache[key]?
        return cached if cached
        # Evict stale entries (different version) so the cache doesn't grow
        # without bound as the user edits.
        @cells_written_cache.reject! { |k, _| k[0] != @version }
        result = Set({FieldLID, RecordLID}).new
        @field2record2commit2value.each do |field_lid, r2c2v|
            next if field_lid < 0
            r2c2v.each do |record_lid, c2v|
                next unless c2v.has_key?(commit)
                result.add({field_lid.as(FieldLID), record_lid.as(RecordLID)})
            end
        end
        @cells_written_cache[key] = result
        result
    end

    # Records in `table_lid` with any write at `commit`: cell writes (via
    # cells_written_at) plus records newly added at `commit` (Predecessors
    # entries whose BelongsTo is the table — covers records with no user-field
    # cells yet).
    def records_with_writes_at(commit : CommitLID, table_lid : TableLID) : Array(RecordLID)
        seen = Set(RecordLID).new
        # Pass 1: from cell-level writes
        cells_written_at(commit).each do |f, r|
            belongs = get_value(MetaFieldLIDs::BelongsTo, f)
            next unless belongs.is_a?(Int64)
            seen.add(r) if belongs.as(TableLID) == table_lid
        end
        # Pass 2: newly-created records (Predecessors[new_record_lid] at commit,
        # BelongsTo[new_record_lid] == table_lid, no Names → a record, not a field)
        if predecessors = @field2record2commit2value[MetaFieldLIDs::Predecessors]?
            predecessors.each do |new_lid, c2v|
                next unless c2v.has_key?(commit)
                belongs = get_value(MetaFieldLIDs::BelongsTo, new_lid.as(FieldLID))
                next unless belongs.is_a?(Int64)
                next unless belongs.as(TableLID) == table_lid
                next unless get_value(MetaFieldLIDs::Names, new_lid.as(FieldLID)).nil?
                seen.add(new_lid.as(RecordLID))
            end
        end
        seen.to_a
    end

    # Move writes for a subset of tables from one commit to another. Used for
    # "selective commit": the user unchecks some tables in the changes summary
    # and hits Commit!. The unchecked tables' writes float to the next open
    # commit while the checked ones stay in the commit being closed.
    #
    # Atomic: wrapped in transaction so the data is consistent on failure.
    # Touches Predecessors / TableLastRecord / TableLastField / BelongsTo /
    # Names meta writes too, so record-add / field-add clusters float as a
    # single unit (every meta write associated with the added LID moves along).
    def float_writes(from : CommitLID, to : CommitLID, defer_tables : Set(TableLID)) : Nil
        return if defer_tables.empty?
        transaction do
            @field2record2commit2value.each do |field_lid, r2c2v|
                r2c2v.each do |record_lid, c2v|
                    next unless c2v.has_key?(from)
                    tlid = table_of(field_lid, record_lid)
                    next if tlid.nil?
                    next unless defer_tables.includes?(tlid)
                    value = c2v[from]
                    c2v.delete(from)
                    c2v[to] = value
                end
            end
            @version += 1
            @meta_version += 1
        end
    end

    # Given a (field, record) pair, return the user-visible TableLID it belongs
    # to, or nil if it's an internal meta entry that isn't associated with a
    # user table. Used by float_writes to route meta-writes (Predecessors,
    # TableLastRecord, TableLastField, BelongsTo, Names) alongside the
    # corresponding net-cell writes so record-add / field-add clusters float
    # together.
    private def table_of(field_lid : FieldLID, record_lid : RecordLID) : TableLID?
        case field_lid
        when MetaFieldLIDs::TableLastRecord, MetaFieldLIDs::TableLastField
            # record_lid here is a TableLID
            rid = record_lid.as(TableLID)
            rid < 0 ? nil : rid
        when MetaFieldLIDs::Predecessors, MetaFieldLIDs::BelongsTo, MetaFieldLIDs::Names
            # record_lid is a RecordLID or FieldLID whose BelongsTo gives its table
            belongs = get_value(MetaFieldLIDs::BelongsTo, record_lid.as(FieldLID))
            return nil unless belongs.is_a?(Int64)
            tlid = belongs.as(TableLID)
            tlid < 0 ? nil : tlid
        when MetaFieldLIDs::RootCommit, MetaFieldLIDs::RefersTo
            nil  # commit graph + reference links aren't per-table
        else
            return nil if field_lid < 0  # any other meta — skip
            # Net-field write: owning table via BelongsTo on the field
            belongs = get_value(MetaFieldLIDs::BelongsTo, field_lid)
            return nil unless belongs.is_a?(Int64)
            tlid = belongs.as(TableLID)
            tlid < 0 ? nil : tlid
        end
    end
    private def is_commit_closed? : Bool
        # a commit is closed if it already has a successor
        has_succ = false
        @field2record2commit2value[MetaFieldLIDs::RootCommit].each do |record, commit2value|
            commit2value.each do |commit, value|
                has_succ ||= (commit == MetaFieldLIDs::RootCommit) && (value == context.current_commit) # are we predecessor of some other commit?
            end
        end
        has_succ
    end
    # Dispatches meta-field (field_lid < 0) reads to the metadata path,
    # net-field reads to the net path. Used by get_value / get_field_internal /
    # get_ancestors so that a Shape can clamp net visibility (e.g. to a single
    # commit for a diff view) without losing the full schema history.
    private def path_for_field(field_lid : FieldLID) : Array(CommitLID)
        if field_lid < 0
            commit_path_for(context.metadata_root_commit, context.metadata_commit)
        else
            commit_path_for(context.root_commit, context.current_commit)
        end
    end
    private def get_commit_path : Array(CommitLID)
        # Net path (backward-compat convenience for call sites that haven't been
        # migrated). New code should prefer path_for_field.
        commit_path_for(context.root_commit, context.current_commit)
    end
    # Walk from `current` backwards until we either hit `root` (inclusive) or
    # run out of predecessors. Handles root == current correctly by stopping
    # immediately; older impl walked past root in that case.
    private def commit_path_for(root : CommitLID, current : CommitLID) : Array(CommitLID)
        pred = @field2record2commit2value[MetaFieldLIDs::RootCommit].map do |record, commit2value|
            commit2value.select do |commit, value|
                commit == MetaFieldLIDs::RootCommit
            end.map {|commit, value| {record,value.as(CommitLID)}}
        end.flatten.to_h # flatten to remove empty arrays (coming from non-RootCommits)
        commit = current
        path = [commit]
        while commit != root
            pc = pred[commit]?
            break if pc.nil?
            path << pc
            commit = pc
        end
        path.reverse # [oldest, ..., newest]
    end
end # class Persistency::Backend::Memory(T)

# introduces the following MetaFieldLIDs: Names, TableLastField, TableLastRecord, RefersTo, BelongsTo
module Persistency::Generic::Basics(T)
    # T should include Nil (which is equivalent to "not set" / "not available" / "unused")
    abstract def get_value(field_lid : FieldLID, record_lid : RecordLID) : T
    abstract def set_value(field_lid : FieldLID, record_lid : RecordLID, value : T)
    protected abstract def get_ancestors(start_lid : Int64) : Array(RecordLID)
    protected abstract def get_field_internal(field_lid : FieldLID) : Hash(RecordLID,T) # retrieves all values of field (also potentially deleted ones!)
    protected abstract def get_new_lid : Int64
    def initialize
        super
        # make Names part of the pseudo table TableLastField
        set_value(MetaFieldLIDs::TableLastField, MetaFieldLIDs::TableLastTable, MetaFieldLIDs::Names)
    end
    protected def initialize(other : self) # for cloning
        super
    end
    def set_value(field_lid : FieldLID, record_lid : RecordLID, value : T) # this is a more restricted version
        if get_value(MetaFieldLIDs::RefersTo, field_lid)
            assert(value.is_a?(RecordLID) || value.nil?) # preventing Persistency corruption
        end
        super
    end
    def get_field(field_lid : FieldLID, sparse = true) : Hash(RecordLID,T) # retrieves all (sparse or dense) values of field (vs. #get_ancestors)
        if field_lid > 0 # non-meta fields need to have record_lid defined
            if table_lid = get_table_lid(field_lid)
                record_lids = get_record_lids(table_lid)
            else
                record_lids = Array(RecordLID).new # field already removed -> empty result
            end
        else
            record_lids = nil
        end
        record2values = get_field_internal(field_lid)
        if record_lids.nil?
            record2values.reject {|k,v| sparse && v.nil?}
        else
            record_lids.map {|record_lid| {record_lid, record2values[record_lid]?}}.to_h .reject {|k,v| sparse && v.nil?}
        end
    end
    def add_table(name : String) : TableLID
        table_lid = add_record(MetaFieldLIDs::TableLastTable) # extend table sequence
        set_value(MetaFieldLIDs::Names, table_lid, name)
        set_value(MetaFieldLIDs::TableLastField, table_lid, nil)
        set_value(MetaFieldLIDs::TableLastRecord, table_lid, nil)
        table_lid
    end
    def remove_table(table_lid : TableLID) : Nil
        get_field_lids(table_lid).each do |field_lid|
            remove_field(table_lid, field_lid)
        end
        set_value(MetaFieldLIDs::Names, table_lid, nil)
        remove_record(MetaFieldLIDs::TableLastTable, table_lid)
        set_value(MetaFieldLIDs::TableLastRecord, table_lid, nil) # leaves the linked list mostly in, but removes the entry point
    end
    def add_field(table_lid : TableLID, name : String, refers_to_field_lid : FieldLID? = nil) : FieldLID
        predfield = get_value(MetaFieldLIDs::TableLastField, table_lid)
        field_lid = get_new_lid
        set_value(MetaFieldLIDs::Names, field_lid, name)
        set_value(MetaFieldLIDs::BelongsTo, field_lid, table_lid)
        set_value(MetaFieldLIDs::TableLastField, table_lid, field_lid)
        set_value(MetaFieldLIDs::Predecessors, field_lid, predfield)
        if refers_to_field_lid
            assert(get_value(MetaFieldLIDs::RefersTo, refers_to_field_lid).nil?)
            set_value(MetaFieldLIDs::RefersTo, field_lid, refers_to_field_lid)
        end
        field_lid
    end
    def move_field(table_lid : TableLID, from_lid : FieldLID, to_lid : FieldLID) # "replace rank" semantics
        last_field_lid = get_value(MetaFieldLIDs::TableLastField, table_lid).as(FieldLID)
        fieldlid2rank = get_field_lids(table_lid).map_with_index {|el,i| {el,i} }.to_h
        from_rank = fieldlid2rank[from_lid]
        to_rank = fieldlid2rank[to_lid]
        to_lid = get_successor(to_lid, last_field_lid) if to_rank > from_rank # in case of array miss -> last element
        from_end_lid = get_successor(from_lid, last_field_lid)
        move_record_or_field(table_lid, from_lid, from_end_lid, to_lid, MetaFieldLIDs::TableLastField) if from_rank != to_rank
    end
    def remove_field(table_lid : TableLID, lid : FieldLID)
        # removes field from meta data, but keeps net data untouched
        remove(table_lid, lid, MetaFieldLIDs::TableLastField)
        set_value(MetaFieldLIDs::Names, lid, nil)
        set_value(MetaFieldLIDs::BelongsTo, lid, nil)
        set_value(MetaFieldLIDs::RefersTo, lid, nil)
    end
    def add_record(table_lid : TableLID) : RecordLID
        # considered meta data: Predecessors, TableLastRecord
        predrecord = get_value(MetaFieldLIDs::TableLastRecord, table_lid)
        record_lid = get_new_lid
        set_value(MetaFieldLIDs::BelongsTo, record_lid, table_lid)
        set_value(MetaFieldLIDs::TableLastRecord, table_lid, record_lid)
        set_value(MetaFieldLIDs::Predecessors, record_lid, predrecord)
        record_lid
    end
    def remove_record(table_lid : TableLID, record_lid : RecordLID) # we explicitly allow remove of elements not in the list (useful for multiple calls)
        remove(table_lid, record_lid, MetaFieldLIDs::TableLastRecord)
        set_value(MetaFieldLIDs::BelongsTo, record_lid, nil)
    end
    def get_field_lids(table_lid : TableLID) : Array(FieldLID)
        last_field_lid = get_value(MetaFieldLIDs::TableLastField, table_lid)
        if last_field_lid.nil?
            [] of FieldLID
        else
            get_ancestors(last_field_lid.as(FieldLID))
        end
    end
    def get_table_lid(field_lid : FieldLID) : TableLID?
        get_value(MetaFieldLIDs::BelongsTo, field_lid).as(TableLID?)
    end
    def get_outward_reference(field_lid : FieldLID) : FieldLID?
        get_value(MetaFieldLIDs::RefersTo, field_lid).as(FieldLID?)
    end
    def get_inward_references(field_lid : FieldLID) : Array(FieldLID)
        field = get_field(MetaFieldLIDs::RefersTo)
        field.select {|k,v| v==field_lid}.map {|k,v| k.as(FieldLID)}
    end
    def move_record_by_rank(table_lid : TableLID, from_rank : Int32, to_rank : Int32) : Int32 # new (proper) rank
        records = get_record_lids(table_lid)
        to_rank = 1 if to_rank < 1
        to_rank = records.size if to_rank > records.size
        res = to_rank
        to_rank += 1 if to_rank > from_rank # in case of array miss -> last element
        move_record(table_lid, records[from_rank-1], records[to_rank-1]?) if from_rank != to_rank
        res
    end
    def get_table(table_lid : TableLID) : Array(Array(T)) # a shorthand; including leading RecordLID and Rank columns
        complex_query({table_lids: [table_lid], field_lids: [get_field_lids(table_lid)], table_joins: [] of {Int32,Int32}, where_not_nil_columns: [] of Int32}, false)
    end
    private class ComplexQuery(T)
        enum SpecialFields
            Record
            Rank
        end
        private alias InternalFieldLID = FieldLID|SpecialFields
        def initialize(@backend : Persistency::Generic::Basics(T))
            @tableindex2record2rowindices = Hash(Int32,Hash(RecordLID, Array(Int32))).new do |hash,key|
                hash[key] = Hash(RecordLID, Array(Int32)).new do |hash,key|
                    hash[key] = Array(Int32).new
                end
            end
            @columnindex2tableindex_fieldlid = Hash(Int32,{Int32,InternalFieldLID}).new
            @rowindex2tableindex_records = Hash(Int32,Array({Int32, RecordLID?})).new do |hash,key|
                hash[key] = Array({Int32, RecordLID?}).new
            end
            @recordlid2rank = Hash(RecordLID,Int32).new
        end
        def join(table_lid rhs_table_lid : TableLID, field_lid rhs_field_lid : FieldLID?=nil, columnindex : Int32=-1)
            # #join just adds a new "record_lid" column to LHS (rest needs to be done via #add_field)
            # rhs_field_lid.nil?: record_lid shall be used for rhs
            # columnindex<0: no join, just fill in (first) table
            if rhs_field_lid # rhs references lhs, so lhs must be RecordLID
                assert(@columnindex2tableindex_fieldlid[columnindex][1] == SpecialFields::Record)
                record_lids_lhs2rhs = get_field_reversed(rhs_field_lid) # Hash(RecordLID,Set(RecordLID))
            elsif columnindex >= 0 # lhs references rhs, so rhs must be RecordLID
                lhs_field_lid = @columnindex2tableindex_fieldlid[columnindex][1].as(FieldLID)
                record_lids_lhs2rhs = @backend.get_field(lhs_field_lid).map {|k,v| {k,Set{v.as(RecordLID|Nil)}}}.to_h
            else
                # this is the first "join", nothing to reference
            end
            rhs_table_index = @tableindex2record2rowindices.size
            rhs_column_index = @columnindex2tableindex_fieldlid.size
            rhs_record_lids = @backend.get_record_lids(rhs_table_lid).map_with_index {|record_lid,rank| {record_lid,rank+1}}.to_h # Hash(RecordLID,Int32)
            @columnindex2tableindex_fieldlid[rhs_column_index] = {rhs_record_lids.size > 0 ? rhs_table_index : -1, SpecialFields::Record} # we use -1 for an empty table
            @recordlid2rank.merge!(rhs_record_lids)
            # part 1: left join the flat table (all in @*, "left") with the new table (rhs_table_lid, "right")
            if columnindex >= 0
                lhs_table_index, _ = @columnindex2tableindex_fieldlid[columnindex]
                lhs_record2rowindices = @tableindex2record2rowindices[lhs_table_index]
                # we do left join, removing the joined entries; this means keeping left table, adding matching parts of the right table
                record_lids_lhs2rhs.not_nil!.each do |lhs_record_lid,rhs_record_lids_part|
                    row_indices = lhs_record2rowindices[lhs_record_lid].dup # Array(Int32), the rows in lhs which all have the same record_lid
                    rhs_record_lids_part.each_with_index do |rhs_record_lid,i|
                        if i == rhs_record_lids_part.size-1
                            current_rows = row_indices # no clone for last record_lid
                        else
                            current_rows = row_indices.map {|el| clone_row(el)}
                        end
                        # fill `current_rows` (LHS) with `rhs_record_lid`
                        current_rows.each do |row_index|
                            @tableindex2record2rowindices[rhs_table_index][rhs_record_lid] << row_index if rhs_record_lid
                            @rowindex2tableindex_records[row_index] << {rhs_table_index, rhs_record_lid}
                        end
                        rhs_record_lids.delete(rhs_record_lid) if current_rows.size > 0 # exclude those record_lids from the second part below
                    end
                end
            end
            # part 2: now we do right join with the remaining entries (with no counterparts of the left table)
            rhs_record_lids.each_key do |rhs_record_lid|
                row_index = @rowindex2tableindex_records.size
                @tableindex2record2rowindices[rhs_table_index][rhs_record_lid] << row_index
                @rowindex2tableindex_records[row_index] << {rhs_table_index, rhs_record_lid}
            end
        end
        def add_field(field_lid : InternalFieldLID)
            table_index = @tableindex2record2rowindices.last_key? || -1 # we use -1 for an empty table
            column_index = @columnindex2tableindex_fieldlid.size
            @columnindex2tableindex_fieldlid[column_index] = {table_index, field_lid}
        end
        def filter_and_sort(where_not_nil_columns : Array(Int32), where_not_nil_anding : Bool) : Array(Array(T))
            where_not_nil_columns = where_not_nil_columns.to_set
            rank_columns = Array(Int32).new
            @columnindex2tableindex_fieldlid.each do |column_index, v|
                rank_columns << column_index if v[1] == SpecialFields::Rank
            end
            run.select do |row|
                cols = row.select_with_index {|_,i| where_not_nil_columns.includes?(i)}.map {|el| !!el}
                red = cols.reduce? {|x,y| where_not_nil_anding ? (x && y) : (x || y)}
                red.nil? ? true : red
            end.sort do |row1, row2|
                rank_columns.map {|i| mycmp(row1[i],row2[i])}.find {|el| el != 0}
            end
        end
        private def run : Array(Array(T))
            res = Array(Array(T)).new(@rowindex2tableindex_records.size) do
                Array(T).new(@columnindex2tableindex_fieldlid.size, nil) # independent rows
            end
            fields = Hash(FieldLID, Hash(RecordLID,T)).new
            @columnindex2tableindex_fieldlid.each do |column_index, v|
                table_index, field_lid = v
                if table_index >= 0 # we use -1 for an empty table
                    @tableindex2record2rowindices[table_index].each do |record_lid, row_indices|
                        row_indices.each do |row_index|
                            value = nil
                            case field_lid
                            when SpecialFields::Record
                                value = record_lid if @recordlid2rank[record_lid]?
                            when SpecialFields::Rank
                                rank = @recordlid2rank[record_lid]?
                                value = rank ? rank.to_i64 : nil
                            else
                                field_lid = field_lid.as(FieldLID)
                                if !fields[field_lid]?
                                    fields[field_lid] = @backend.get_field(field_lid)
                                end
                                value = fields[field_lid][record_lid]?
                            end
                            res[row_index][column_index] = value
                        end
                    end
                end
            end
            res
        end
        private def get_field_reversed(field_lid : FieldLID) : Hash(RecordLID,Set(RecordLID))
            res = Hash(RecordLID,Set(RecordLID)).new
            field = @backend.get_field(field_lid) # Hash(RecordLID,T), in our case T should be RecordLID as well
            field.each do |k,v|
                if v # in case v is nil we just drop it here
                    v = v.as(RecordLID)
                    res[v] ||= Set(RecordLID).new
                    res[v] << k
                end
            end
            res
        end
        private def clone_row(row_index : Int32) : Int32
            row_index2 = @rowindex2tableindex_records.size
            @rowindex2tableindex_records[row_index2] = @rowindex2tableindex_records[row_index].clone
            @rowindex2tableindex_records[row_index2].each do |table_index, record_lid|
                @tableindex2record2rowindices[table_index][record_lid.not_nil!] << row_index2
            end
            row_index2
        end
    end
    def complex_query(query : {table_lids: Array(TableLID), field_lids: Array(Array(FieldLID)), table_joins: Array({Int32,Int32}), where_not_nil_columns: Array(Int32)}, where_not_nil_anding : Bool) : Array(Array(T))
        cq = ComplexQuery(T).new(self)
        query[:table_lids].size.times do |table_index|
            table_lid = query[:table_lids][table_index]
            field_lids = query[:field_lids][table_index]
            if table_index == 0
                cq.join(table_lid)
            else
                lhs_column, rhs_column = query[:table_joins][table_index-1]
                field_lid = (rhs_column==0 ? nil : field_lids[rhs_column-2]) # `nil` is here a shorthand for record_lid column; otherwise we skip two pseudofields RecordLID and Rank
                cq.join(table_lid, field_lid, lhs_column)
            end
            cq.add_field(ComplexQuery::SpecialFields::Rank)
            field_lids.each do |field_lid|
                cq.add_field(field_lid)
            end
        end
        res = cq.filter_and_sort(query[:where_not_nil_columns], where_not_nil_anding)
        res
    end
    def get_record_lids(table_lid : TableLID) : Array(RecordLID)
        last_record_lid = get_value(MetaFieldLIDs::TableLastRecord, table_lid)
        if last_record_lid.nil?
            [] of RecordLID
        else
            get_ancestors(last_record_lid.as(FieldLID))
        end
    end
    private def move_record_or_field(table_lid : TableLID, from_start : RecordLID, from_end : RecordLID?, to_before : RecordLID?, meta : FieldLID)
        # the records/fields (from_start...from_end), i.e. exclusive the end, get moved before "to_before"
        # nil marks the end beyond the last record/field
        # assumption: from_start needs to be an (indirect) predecessor of from_end
        # special cases: from_end==nil or to_before=nil -> MetaFieldLIDs::TableLastRecord, record_lid is table_lid
        from_end_field = to_before_field = MetaFieldLIDs::Predecessors
        if !from_end
            from_end_field = meta
            from_end = table_lid
        end
        if !to_before
            to_before_field = meta
            to_before = table_lid
        end
        if from_end != to_before # otherwise it should be a no-op #take (see booklet 3.4.2023 and 22.8.2023)
            # now read...
            from_end_pred = get_value(from_end_field, from_end)
            from_start_pred = get_value(MetaFieldLIDs::Predecessors, from_start)
            to_before_pred = get_value(to_before_field, to_before)
            # ... and write
            set_value(from_end_field, from_end, from_start_pred)
            set_value(MetaFieldLIDs::Predecessors, from_start, to_before_pred)
            set_value(to_before_field, to_before, from_end_pred)
        end
    end
    private def move_record(table_lid : TableLID, from_start : RecordLID, to_before : RecordLID?)
        last_record_lid = get_value(MetaFieldLIDs::TableLastRecord, table_lid).as(FieldLID)
        from_end = get_successor(from_start, last_record_lid)
        move_record_or_field(table_lid, from_start, from_end, to_before, MetaFieldLIDs::TableLastRecord)
    end
    private def remove(table_lid : TableLID, lid : Int64, meta_representant_lid : Int64)
        last_record_or_nil = get_value(meta_representant_lid, table_lid)
        return if last_record_or_nil.nil? # table already empty; consistent with tolerating remove of elements not in list
        last_record = last_record_or_nil.as(RecordLID)
        predlid = get_value(MetaFieldLIDs::Predecessors, lid)
        succlid = get_successor(lid, last_record)
        set_value(MetaFieldLIDs::Predecessors, lid, nil)
        if succlid
            set_value(MetaFieldLIDs::Predecessors, succlid, predlid)
        elsif lid == last_record # otherwise: was not in the list at all (probably severals #remove called in a row by higher layer)
            set_value(meta_representant_lid, table_lid, predlid) # we remove last record/field
        end
    end
end # module Persistency::Generic::Basics(T)

#################################

# beware: "uses" Memory does not work, since then (expansive!) internal calls inside Memory (e.g. #is_commit_closed?) bypass the cache
# -> hence we inherit (specifically from Memory); other solution might be to do partial caching already directly in Memory...
# observation: serialization works if directly using Memory or Cacher - on both file formats!
# Cacher is mainly speeding up:
# - #get_value (both for known values and new (nil) values)
# - #set_value (indirectly by speeding up #is_commit_closed?)
# - #remove_record (indirectly by speeding up #get_successor), dito #move_record
# this way loading, importing, bulk deletions are significantly sped up
class Persistency::Backend::Cacher(T) < Persistency::Backend::Memory(T)
    @[JSON::Field(ignore: true)]
    @cache = Hash({FieldLID,RecordLID,CommitLID,CommitLID},T).new
    @[JSON::Field(ignore: true)]
    @new_lids = Set({CommitLID,CommitLID,Int64}).new
    @[JSON::Field(ignore: true)]
    @commit_states = Hash(CommitLID,Bool).new
    @[JSON::Field(ignore: true)]
    @successors = BidirHash({CommitLID,CommitLID,RecordLID},{CommitLID,CommitLID,RecordLID}).new
    def get_value(field_lid : FieldLID, record_lid : RecordLID) : T
        key = {field_lid,record_lid,context.root_commit,context.current_commit}
        if @cache.has_key?(key) || @new_lids.includes?({context.root_commit,context.current_commit,record_lid}) || @new_lids.includes?({context.root_commit,context.current_commit,field_lid})
            @cache[key]?
        else
            @cache[key] = super
        end
    end
    def set_value(field_lid : FieldLID, record_lid : RecordLID, value : T)
        # first, delete old successor
        update_successor = (field_lid == MetaFieldLIDs::Predecessors) #|| (field_lid == MetaFieldLIDs::TableLastTable) || (field_lid == MetaFieldLIDs::TableLastField) || (field_lid == MetaFieldLIDs::TableLastRecord)
        if update_successor
            if predlid = get_value(MetaFieldLIDs::Predecessors, record_lid).as(RecordLID?)
                @successors.delete({context.root_commit,context.current_commit,predlid})
            end
        end
        super # then call Memory...
        if update_successor && value.is_a?(RecordLID)
            if predlid = get_value(MetaFieldLIDs::Predecessors, value).as(RecordLID?)
                @successors[{context.root_commit,context.current_commit,predlid}] = {context.root_commit,context.current_commit,value}
            end
        end
        key = {field_lid,record_lid,context.root_commit,context.current_commit}
        @cache[key] = value # ... only second fill cache (since Memory might (but should not anymore!) first call #get internally, which we <- here need to overwrite!)
    end
    def close_and_add_commit : CommitLID
        @commit_states[context.current_commit] = true
        super # call this at end, since it has side effect to context
    end
    def float_writes(from : CommitLID, to : CommitLID, defer_tables : Set(TableLID)) : Nil
        super
        # Caches are keyed by (root, current) and can reference any of the
        # moved (field, record) cells — drop everything rather than try to
        # invalidate surgically.
        @cache.clear
        @new_lids.clear
        @commit_states.clear
        @successors.clear
    end
    protected def get_new_lid : Int64
        lid = super
        @new_lids.add({context.root_commit,context.current_commit,lid})
        lid
    end
    protected def get_successor(predlid : RecordLID, last_lid : RecordLID) : RecordLID? # trying to avoid #get_ancestors
        if predlid == last_lid
            nil
        else
            key = {context.root_commit,context.current_commit,predlid}
            if !@successors.has_key?(key)
                record_lids = get_ancestors(last_lid)
                record_lids.each_cons_pair do |predlid, lid|
                    @cache[{MetaFieldLIDs::Predecessors,lid,context.root_commit,context.current_commit}] = predlid # for regular #get_value
                    @successors[{context.root_commit,context.current_commit,predlid}] = {context.root_commit,context.current_commit,lid}
                end
            end
            if v = @successors[key]? # if not in list at all -> nil
                v[2]
            else
                nil
            end
        end
    end
    private def is_commit_closed? : Bool
        if @commit_states.has_key?(context.current_commit)
            @commit_states[context.current_commit]
        else
            @commit_states[context.current_commit] = super
        end
    end
end

#################################

require "crexcel"
require "xlsx-parser"
module Persistency::Generic::ImExport(T)
    abstract def add_table(name : String) : TableLID
    abstract def add_record(table_lid : TableLID) : RecordLID
    abstract def add_field(table_lid : TableLID, name : String, refers_to_field_lid : FieldLID? = nil) : FieldLID
    abstract def get_value(field_lid : FieldLID, record_lid : RecordLID) : T
    abstract def set_value(field_lid : FieldLID, record_lid : RecordLID, value : T)
    abstract def get_field_lids(table_lid : TableLID) : Array(FieldLID)
    abstract def get_record_lids(table_lid : TableLID) : Array(RecordLID)
    def import(file : String, tablename : String) : TableLID
        book = XlsxParser::Book.new(file)
        if book.sheets[0].rows.size >= 2
            table_lid = add_table(tablename)
            header = nil
            field_lids = [] of FieldLID
            book.sheets[0].rows.each do |row|
                if header
                    record_lid = add_record(table_lid)
                    row.each_value.with_index do |v,i| # {"A1" => 42, "B1" => nil, "C1" => "fourtytwo"}
                        v = case v
                        when Time
                            nil
                        when Int32
                            v.to_i64
                        else
                            v
                        end
                        set_value(field_lids[i], record_lid, v)
                    end
                else
                    header = row # {"A1" => 42, "B1" => nil, "C1" => "fourtytwo"}
                    header.each_value do |v|
                        field_lid = add_field(table_lid, v.as(String))
                        field_lids << field_lid
                    end
                end
            end
        end
        book.close
        table_lid.not_nil!
    end
    def export(file : String, table_lid : TableLID)
        workbook = Crexcel::Workbook.new(file)
        worksheet = workbook.add_worksheet("export")
        # header
        field_lids = get_field_lids(table_lid)
        record_lids = get_record_lids(table_lid)
        header = field_lids.map {|field_lid| get_value(MetaFieldLIDs::Names, field_lid).to_s}
        worksheet.write_row(0, header)
        # content
        record_lids.each.with_index do |record_lid,i|
            # needs some patching if nil is to be part of #write_row
            row = field_lids.map do |field_lid|
                value = get_value(field_lid, record_lid)
                case value
                when Float64, Int64, String, Nil
                    value
                when true
                    1
                when false
                    0
                else
                    assert(false)
                end
            end
            worksheet.write_row(1+i, row)
        end
        workbook.close
    end
end # module Persistency::Generic::ImExport(T)

#################################

# attention: #load does _not_ set the current commit in context, i.e. will be 0
require "compress/zlib"
module Persistency::Generic::LoadSave(T)
    abstract def to_json
    # abstract def self.from_json(data)
    # .embrace = zlib-compressed JSON (open format, no encryption). The data is
    # local and the source is public, so an embedded cipher key would be
    # security theatre; transparency + portability win instead.
    def save : Bytes
        begin
            io = IO::Memory.new
            h = Compress::Zlib::Writer.new(io)
            h << to_json
            h.close
            io.rewind
            io.getb_to_end
        rescue ex
            raise ConditionsNotMet.new("Save failed")
        end
    end
    def load(data : Bytes) : Nil
        begin
            io = IO::Memory.new(data)
            json = Compress::Zlib::Reader.new(io).gets_to_end
            replace(self.class.from_json(json)) # only works like this
        rescue ex
            raise ConditionsNotMet.new("Load failed - format inappropriate")
        end
    end
end # module Persistency::Generic::LoadSave(T)

#################################

module Persistency::Generic::Refactoring(T)
    abstract def get_outward_reference(field_lid : FieldLID) : FieldLID?
    abstract def get_value(field_lid : FieldLID, record_lid : RecordLID) : T
    abstract def set_value(field_lid : FieldLID, record_lid : RecordLID, value : T)
    abstract def add_record(table_lid : TableLID) : RecordLID
    abstract def get_field(field_lid : FieldLID, sparse = true) : Hash(RecordLID,T)
    abstract def get_table_lid(field_lid : FieldLID) : TableLID?
    abstract def add_field(table_lid : TableLID, name : String, refers_to_field_lid : FieldLID? = nil) : FieldLID
    abstract def remove_field(table_lid : TableLID, lid : FieldLID)
    abstract def get_field_lids(table_lid : TableLID) : Array(FieldLID)
    abstract def remove_record(table_lid : TableLID, record_lid : RecordLID)
    abstract def get_record_lids(table_lid : TableLID) : Array(RecordLID)
    # turn field_lid from non-reference into reference and make sure target field carries all necessary keys; no fields added/removed
    def factor_out_reference(table_lid : TableLID, field_lid : FieldLID, target_table_lid : TableLID, target_field_lid : FieldLID) : Bool
        assert(get_table_lid(field_lid) == table_lid)
        assert(get_table_lid(target_field_lid) == target_table_lid)
        assert(table_lid != target_table_lid)
        raise(ConditionsNotMet.new("Field needs to be non-reference")) if !get_outward_reference(field_lid).nil?
        raise(ConditionsNotMet.new("Target field needs to be non-reference")) if !get_outward_reference(target_field_lid).nil?
        value2recordlids = get_values2recordlids(field_lid).to_a.sort {|x,y| mycmp(x[0],y[0])}.to_h # we add the new values in sorted order
        # now we transform the source field lid and create references
        result_is_ambiguous = false
        value2record_lids_target = get_values2recordlids(target_field_lid)
        set_value(MetaFieldLIDs::RefersTo, field_lid, target_field_lid)
        value2recordlids.each do |value, recordlids|
            if values = value2record_lids_target[value]?
                target_record_lid = values.first
                result_is_ambiguous = true if values.size > 1
            else
                # if needed value is not present, we create it
                target_record_lid = add_record(target_table_lid)
                set_value(target_field_lid, target_record_lid, value)
            end
            recordlids.each do |record_lid|
                set_value(field_lid, record_lid, target_record_lid)
            end
        end
        result_is_ambiguous
    end
    # turn field_lid from reference into non-reference; no fields added/removed; works also if referenced table is deleted
    def factor_in_reference(table_lid : TableLID, field_lid : FieldLID) : Nil
        assert(get_table_lid(field_lid) == table_lid) # TODO(persistency): table_lid param otherwise unused
        target_field_lid = get_outward_reference(field_lid)
        raise(ConditionsNotMet.new("Field needs to be reference")) if target_field_lid.nil?
        # now we transform the source field lid and get rid of references
        set_value(MetaFieldLIDs::RefersTo, field_lid, nil)
        get_field(field_lid).each do |record_lid,v|
            if v.is_a?(RecordLID)
                value = get_value(target_field_lid, v) # we do explicitly not use #get_field, because field might already be deleted
            else
                value = nil
            end
            set_value(field_lid, record_lid, value)
        end
    end
    # move field in the reference direction; removes move_field in source_table, creates new field in sink_table
    # may fail in case of ambiguities
    def move_field_outwards(source_table : TableLID, source_field : FieldLID, sink_table : TableLID, move_field : FieldLID) : FieldLID
        # first doing checks
        assert(source_table != sink_table)
        assert(get_table_lid(source_field) == source_table)
        raise ConditionsNotMet.new("Cannot move reference field itself") if source_field == move_field
        assert(get_table_lid(move_field) == source_table) # precondition for #move_field_outwards
        assert(get_table_lid(get_outward_reference(source_field).not_nil!) == sink_table) # source_field has to link both tables
        move_field_references = get_value(MetaFieldLIDs::RefersTo, move_field).as(FieldLID?)
        if move_field_references && (get_table_lid(move_field_references) == sink_table)
            raise ConditionsNotMet.new("Cannot move reference field into referenced table")
        end
        # then gathering infos
        move_field_name = get_value(MetaFieldLIDs::Names, move_field).as(String)
        record_lids = get_record_lids(sink_table).to_set
        hash_source = get_field(source_field).select do |_, target_record_lid|
            # sanitize references
            record_lids.includes?(target_record_lid.as(RecordLID))
        end
        hash_moves = get_field(move_field)
        target_values = Hash(RecordLID, T).new
        hash_moves.each do |record_lid, value|
            if target_record_lid = hash_source[record_lid]?
                target_record_lid = target_record_lid.as(RecordLID)
                if target_values.has_key?(target_record_lid)
                    value_current = target_values[target_record_lid]
                    if value_current != value
                        sink_field = get_outward_reference(source_field).not_nil!
                        referenced_value = get_value(sink_field, target_record_lid)
                        raise ConditionsNotMet.new("Cannot move, field '#{move_field_name}' cannot have several values at once, e.g. at '#{referenced_value}' both '#{value_current}' and '#{value}'")
                    end
                else
                    target_values[target_record_lid] = value
                end
            end
        end
        # finally we apply the changes (no further error possible)
        target_field = add_field(sink_table, move_field_name, move_field_references)
        target_values.each do |record_lid, value|
            set_value(target_field, record_lid, value)
        end
        remove_field(source_table, move_field)
        target_field
    end
    # move field opposite to reference direction; takes move_field in sink_table, creates new field in source_table
    # will _not_ delete original move_field, since there might be residual elements; only used _values_ will be deleted
    def move_field_inwards(source_table : TableLID, source_field : FieldLID, sink_table : TableLID, move_field : FieldLID) : FieldLID
        # first doing checks
        assert(source_table != sink_table)
        assert(get_table_lid(source_field) == source_table)
        assert(get_table_lid(move_field) == sink_table) # precondition for #move_field_inwards
        assert(get_table_lid(get_outward_reference(source_field).not_nil!) == sink_table) # source_field has to link both tables
        source_field_references = get_value(MetaFieldLIDs::RefersTo, source_field).as(FieldLID?)
        if source_field_references == move_field
            raise ConditionsNotMet.new("Cannot move referenced field into referencing table")
        end
        move_field_references = get_value(MetaFieldLIDs::RefersTo, move_field).as(FieldLID?)
        if move_field_references && (get_table_lid(move_field_references) == source_table)
            raise ConditionsNotMet.new("Cannot move reference field into referenced table")
        end
        # then gathering infos
        move_field_name = get_value(MetaFieldLIDs::Names, move_field).as(String)
        hash_source = get_field(source_field)
        hash_moves = get_field(move_field)
        to_be_deleted = Set(RecordLID).new
        # finally we apply the changes
        target_field = add_field(source_table, move_field_name, move_field_references)
        hash_source.each do |record_lid, target_record_lid|
            target_value = hash_moves[target_record_lid]?
            set_value(target_field, record_lid, target_value)
            to_be_deleted.add(target_record_lid) if target_record_lid.is_a?(RecordLID)
        end
        to_be_deleted.each do |record_lid|
            set_value(move_field, record_lid, nil)
        end
        target_field
    end
    # merges two fields (only works if no conflicts); if successful, removes source field; otherwise raises exception
    def merge_fields(table_lid : TableLID, field_lid_source : FieldLID, field_lid_target : FieldLID) : Nil
        assert(field_lid_source != field_lid_target)
        assert(table_lid == get_table_lid(field_lid_source))
        assert(get_table_lid(field_lid_source) == get_table_lid(field_lid_target)) # same table
        if get_outward_reference(field_lid_source) != get_outward_reference(field_lid_source)
            raise ConditionsNotMet.new("Cannot merge, fields have different types")
        end
        values_source = get_field(field_lid_source)
        values_target = get_field(field_lid_target)
        actions = Hash(RecordLID, T).new
        values_source.each do |record_lid, value|
            if values_target.has_key?(record_lid)
                target_value = values_target[record_lid]
                if target_value != value
                    raise ConditionsNotMet.new("Cannot merge, e.g. values '#{value}' and '#{target_value}' are different")
                end
            else
                actions[record_lid] = value
            end
        end
        # checking done, no errors
        actions.each do |record_lid, value|
            set_value(field_lid_target, record_lid, value)
        end
        remove_field(table_lid, field_lid_source)
    end
    # moves associated fields into (given) {mux,value}-field combination
    # can be applied stepwise; remaining fields are considered context, will get duplicated (if necessary)
    # operates inside one table
    # attention: partial association can lead to multiple records (but gets cleared with final association)
    # attention: due to one-table mode this transformation has to take extra care not to lose unused field/record "headers" (singularities)
    # attention: mux field must not be reference (the String _names_ of fields are put inside)
    def associate_fields(table_lid : TableLID, field_lids : Array(FieldLID), mux_field : FieldLID, value_field : FieldLID) : Nil
        # first, checks
        assert(get_table_lid(mux_field) == table_lid)
        assert(get_table_lid(value_field) == table_lid)
        if !get_outward_reference(mux_field).nil?
            raise ConditionsNotMet.new("Cannot associate, classification field cannot be reference field")
        end
        field_lids.each do |lid|
            assert(get_table_lid(lid) == table_lid)
            if get_outward_reference(lid) != get_outward_reference(value_field)
                name1, name2 = {lid, value_field}.map {|el| get_value(MetaFieldLIDs::Names, el)}
                raise ConditionsNotMet.new("Cannot associate, fields have different types, eg. fields '#{name1}' and '#{name2}'")
            end
        end
        # preparation
        field_names = field_lids.map {|lid| get_value(MetaFieldLIDs::Names, lid).as(String)}
        field_used = field_lids.map {false}
        used_fields = [mux_field, value_field]
        context_fields = get_field_lids(table_lid) - field_lids - used_fields # w/o rank; can be empty
        duplicationchecker = Set(Array({FieldLID,T})).new
        # now start
        get_record_lids(table_lid).each do |record_lid|
            # preserve old mux/value pairs (for stepwise association)
            if mux_value = get_value(mux_field, record_lid)
                value = get_value(value_field, record_lid)
                ctx = associate_get_context(record_lid, context_fields)
                rec = add_record(table_lid)
                associate_update_record(rec, ctx + [{mux_field, mux_value}, {value_field, value}])
                record_used = true # we remove this record at the end
            else
                record_used = false # we conditionally remove record at the end
            end
            field_lids.each_with_index do |field_lid, field_index|
                if value = get_value(field_lid, record_lid)
                    record_used = true
                    ctx = associate_get_context(record_lid, context_fields)
                    values = ctx + [{mux_field, field_names[field_index]}] # we disallow multiple (context+mux)-values
                    if !duplicationchecker.includes?(values)
                        duplicationchecker.add(values)
                        rec = add_record(table_lid)
                        associate_update_record(rec, values + [{value_field, value}])
                    end
                    field_used[field_index] = true # mark field as non-singular
                end
            end
            remove_record(table_lid, record_lid) if record_used # delete old record if something of it was used (otherwise preserve record singularity)
        end
        # preserve field singularities
        field_used.each_with_index do |used, field_index|
            if !used # we just add unsed fields at the end, one per record
                record_lid = add_record(table_lid)
                set_value(mux_field, record_lid, field_names[field_index])
            end
        end
        field_lids.each {|lid| remove_field(table_lid, lid)}
    end
    # undos association; creates proper individual fields & removes {mux,value}-fields at the end
    # operates inside one table
    # precondition: we assume to have only single (context+mux)-values; otherwise the last will win
    # attention: mux field must not be reference (the String _names_ of fields are put inside)
    def dissociate_fields(table_lid : TableLID, mux_field : FieldLID, value_field : FieldLID) : Array(FieldLID)
        assert(get_table_lid(mux_field) == table_lid)
        assert(get_table_lid(value_field) == table_lid)
        if !get_outward_reference(mux_field).nil?
            raise ConditionsNotMet.new("Cannot dissociate, classification field cannot be reference field")
        end
        field_name2lid = get_field(mux_field).values.uniq.map(&.to_s).sort.map do |name|
            field_lid = add_field(table_lid, name) # String, never references
            {name, field_lid}
        end.to_h
        context_fields = get_field_lids(table_lid) - [mux_field, value_field]
        context2record_lid = Hash(Array({FieldLID,T}),RecordLID).new
        get_record_lids(table_lid).each do |record_lid|
            mux_value = get_value(mux_field, record_lid).to_s
            value = get_value(value_field, record_lid)
            if mux_value
                field_lid = field_name2lid[mux_value]
                ctx = associate_get_context(record_lid, context_fields)
                if (rec = context2record_lid[ctx]?).nil?
                    rec = add_record(table_lid)
                    context2record_lid[ctx] = rec
                end
                associate_update_record(rec, ctx + [{field_lid, value}])
                remove_record(table_lid, record_lid)
            end
        end
        remove_field(table_lid, mux_field)
        remove_field(table_lid, value_field)
        field_name2lid.values
    end
    private def get_values2recordlids(field_lid : FieldLID) : Hash(T,Set(RecordLID))
        recordlid2value = get_field(field_lid)
        value2recordlids = Hash(T,Set(RecordLID)).new {|hash,key| hash[key] = Set(RecordLID).new}
        recordlid2value.each do |k,v|
            value2recordlids[v].add(k)
        end
        value2recordlids
    end
    private def associate_get_context(record_lid : RecordLID, context_fields : Array(FieldLID)) : Array({FieldLID,T})
        ctx = Array({FieldLID,T}).new
        context_fields.each do |field_lid|
            if value = get_value(field_lid, record_lid)
                ctx << {field_lid, value}
            end
        end
        ctx
    end
    private def associate_update_record(record_lid : RecordLID, field_lidvalue : Array({FieldLID,T}))
        field_lidvalue.each do |field_lid, value|
            set_value(field_lid, record_lid, value)
        end
    end
end

#################################

# attention: linear runtime (in terms of number of CommitLIDs) - user layer needs to do proper caching
# attention: a given commit cannot be mapped to a leaf commit in general; but always, if it only has one commit successor, which is open
module Persistency::Generic::Branches(T)
    abstract def get_field(field_lid : FieldLID, sparse = true) : Hash(RecordLID,T)
    def get_ordered_commit_leaves : Array(CommitLID)
        predecessors = get_field(MetaFieldLIDs::RootCommit) # CommitLID => pred
        closed_commits = Set(CommitLID).new
        commit2tipi = {MetaFieldLIDs::RootCommit=>0} # commit to tip index
        predecessors.each do |current, pred| # we fill all arrays with monotonouos increasing CommitLIDs
            pred = pred.as(CommitLID)
            if closed_commits.includes?(pred)
                # new tip
                commit2tipi[current] = commit2tipi.size
            else
                # move old tip
                commit2tipi[current] = commit2tipi.delete(pred).not_nil!
                closed_commits.add(pred)
            end
        end
        commit2tipi.to_a.sort {|x,y| x[1]<=>y[1]}.map {|el| el[0]}
    end
    def get_leaf(commit_lid : CommitLID) : CommitLID?
        successors = get_commit_successors
        leaf = commit_lid
        while leaf
            succ = successors[leaf]
            case succ.size
            when 0
                break
            when 1
                leaf = succ[0]
            else
                leaf = nil
            end
        end
        leaf
    end
    def get_commit_path(leaf_commit : CommitLID) : Array(CommitLID)
        # attention: we don't check if it's really a leaf commit
        predecessors = get_field(MetaFieldLIDs::RootCommit) # CommitLID => pred
        path = [leaf_commit]
        while (last = path[-1]) && (pred = predecessors[last]?)
            path << pred.as(CommitLID)
        end
        path.reverse
    end
    private def get_commit_successors : Hash(CommitLID, Array(CommitLID)) # CommitLID => [succ1, succ2, ...]
        predecessors = get_field(MetaFieldLIDs::RootCommit) # CommitLID => pred
        successors = Hash(CommitLID, Array(CommitLID)).new {|hash,key| hash[key] = Array(CommitLID).new}
        predecessors.each do |current, pred|
            successors[pred.as(CommitLID)] << current # we fill all arrays with monotonouos increasing CommitLIDs
        end
        successors
    end
end

#################################

# class Persistency::Layer01(T) < Persistency::Backend::Memory(T) # variant w/o cache
class Persistency::Layer01(T) < Persistency::Backend::Cacher(T) # variant w/ cache
    include Persistency::Generic::Basics(T)
    include Persistency::Generic::ImExport(T)
    include Persistency::Generic::LoadSave(T)
    include Persistency::Generic::Refactoring(T)
    include Persistency::Generic::Branches(T)
    def initialize
        super
    end
    protected def initialize(other : self) # for cloning
        super
    end
end # class Persistency::Layer01(T)
