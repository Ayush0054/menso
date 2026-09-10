import GRDB

extension LocalDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_local_observation") { database in
            try database.create(table: "usage_events") { table in
                table.column("id", .text).primaryKey()
                table.column("provider", .text).notNull()
                table.column("session_id", .text).notNull()
                table.column("occurred_at", .datetime).notNull()
                table.column("model", .text)
                table.column("request_id", .text)
                table.column("input_tokens", .integer).notNull().defaults(to: 0)
                table.column("output_tokens", .integer).notNull().defaults(to: 0)
                table.column("cache_read_tokens", .integer).notNull().defaults(to: 0)
                table.column("cache_write_tokens", .integer).notNull().defaults(to: 0)
                table.column("reasoning_tokens", .integer).notNull().defaults(to: 0)
                table.column("uncategorized_tokens", .integer).notNull().defaults(to: 0)
                table.column("source_path", .text).notNull()
            }
            try database.create(
                index: "usage_events_time_provider",
                on: "usage_events",
                columns: ["occurred_at", "provider"]
            )
            try database.create(
                index: "usage_events_session_model",
                on: "usage_events",
                columns: ["session_id", "model"]
            )

            try database.create(table: "file_cursors") { table in
                table.column("path", .text).primaryKey()
                table.column("device_id", .integer).notNull()
                table.column("inode", .integer).notNull()
                table.column("byte_offset", .integer).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "agent_rate_limits") { table in
                table.column("provider", .text).notNull()
                table.column("window", .text).notNull()
                table.column("used_percent", .double).notNull()
                table.column("resets_at", .datetime)
                table.column("is_estimate", .boolean).notNull()
                table.column("observed_at", .datetime).notNull()
                table.primaryKey(["provider", "window"])
            }

            // The security slice owns typed action models. This table is a
            // transport-neutral local audit envelope keyed by its action ID.
            try database.create(table: "actions") { table in
                table.column("id", .text).primaryKey()
                table.column("idempotency_key", .text).notNull().unique()
                table.column("kind", .text).notNull()
                table.column("source", .text).notNull()
                table.column("target_json", .blob).notNull()
                table.column("request_json", .blob)
                table.column("binding_json", .blob).notNull()
                table.column("policy_decision", .text)
                table.column("status", .text).notNull()
                table.column("result_json", .blob)
                table.column("execution_json", .blob)
                table.column("evidence_ref", .text)
                table.column("undo_deadline", .datetime)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try database.create(index: "actions_status_time", on: "actions", columns: ["status", "created_at"])

            try database.create(table: "action_execution_reservations") { table in
                table.column("idempotency_key", .text).primaryKey()
                table.column("action_id", .text).notNull()
                table.column("binding_json", .blob).notNull()
                table.column("reservation_json", .blob).notNull()
                table.column("reserved_at", .datetime).notNull()
            }

            try database.create(table: "action_audit_events") { table in
                table.autoIncrementedPrimaryKey("sequence")
                table.column("action_id", .text).notNull()
                    .references("actions", column: "id", onDelete: .cascade)
                table.column("event_type", .text).notNull()
                table.column("payload_json", .blob).notNull()
                table.column("recorded_at", .datetime).notNull()
            }
            try database.create(
                index: "action_audit_events_action_sequence",
                on: "action_audit_events",
                columns: ["action_id", "sequence"]
            )

            try database.create(table: "settings") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "positions") { table in
                table.column("display_id", .text).primaryKey()
                table.column("edge", .text).notNull()
                table.column("fractional_offset", .double).notNull()
                table.column("is_peeking", .boolean).notNull().defaults(to: false)
                table.column("updated_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v4_agentos_continuation_outbox") { database in
            try database.create(table: "agentos_continuation_outbox") { table in
                table.column("id", .text).primaryKey()
                table.column("endpoint_kind", .text).notNull()
                table.column("executor_id", .text).notNull()
                table.column("run_id", .text).notNull()
                table.column("user_id", .text).notNull()
                table.column("session_id", .text).notNull()
                table.column("payload_hash", .text).notNull()
                table.column("payload_json", .blob).notNull()
                table.column("delivery_state", .text).notNull().defaults(to: "pending")
                table.column("delivery_nonce", .text).notNull()
                table.column("attempt_count", .integer).notNull().defaults(to: 0)
                table.column("next_attempt_at", .datetime).notNull()
                table.column("last_error_code", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("delivered_at", .datetime)
                table.uniqueKey(["endpoint_kind", "executor_id", "run_id", "payload_hash"])
            }
            try database.create(
                index: "agentos_continuation_outbox_due",
                on: "agentos_continuation_outbox",
                columns: ["delivery_state", "next_attempt_at", "created_at"]
            )
            try database.create(
                index: "agentos_continuation_outbox_nonce",
                on: "agentos_continuation_outbox",
                columns: ["delivery_nonce"],
                unique: true
            )

            try database.create(table: "trusted_run_authorities") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull()
                table.column("authority_json", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
                table.column("expires_at", .datetime).notNull()
            }
            try database.create(
                index: "trusted_run_authorities_expiry",
                on: "trusted_run_authorities",
                columns: ["expires_at"]
            )
        }

        migrator.registerMigration("v5_pending_run_reviews") { database in
            // Exact app-owned review envelopes. They contain no closures and no
            // reconstructed model authority; only backend Agent/Workflow review
            // contexts are eligible for restart recovery.
            try database.create(table: "pending_run_reviews") { table in
                table.column("action_id", .text).primaryKey()
                table.column("requirement_json", .blob).notNull()
                table.column("request_json", .blob).notNull()
                table.column("context_json", .blob).notNull()
                table.column("resolved_context_json", .blob)
                table.column("envelope_hash", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("expires_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try database.create(
                index: "pending_run_reviews_expiry",
                on: "pending_run_reviews",
                columns: ["expires_at", "created_at"]
            )
        }

        return migrator
    }
}
