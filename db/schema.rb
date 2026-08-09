# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_07_000001) do

  create_table "browser_session_cookies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.datetime "expires_at", null: false
    t.text "payload", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_browser_session_cookies_on_domain", unique: true
  end
  create_table "chat_messages", force: :cascade do |t|
    t.text "content", null: false
    t.integer "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "discord_user_id"
    t.string "discord_username"
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "id"], name: "index_chat_messages_on_conversation_id_and_id"
    t.index ["conversation_id"], name: "index_chat_messages_on_conversation_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "discord_channel_id", null: false
    t.string "discord_user_id"
    t.datetime "last_active_at", null: false
    t.string "scope", null: false
    t.boolean "shared", default: false, null: false
    t.text "summary"
    t.integer "summary_covers_upto_id"
    t.datetime "summary_failed_at"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["scope", "last_active_at"], name: "index_conversations_on_scope_and_last_active_at"
    t.index ["scope"], name: "index_conversations_on_active_scope", unique: true, where: "active = 1"
  end

  create_table "discovered_profiles", force: :cascade do |t|
    t.text "bio"
    t.string "classification"
    t.text "classification_reason"
    t.datetime "classified_at"
    t.datetime "created_at", null: false
    t.string "platform", null: false
    t.string "profile_url"
    t.integer "source_profile_id"
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["classification"], name: "index_discovered_profiles_on_classification"
    t.index ["platform", "username"], name: "index_discovered_profiles_on_platform_and_username", unique: true
    t.index ["source_profile_id"], name: "index_discovered_profiles_on_source_profile_id"
  end

  create_table "events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.date "end_date"
    t.string "event_type"
    t.string "image_url"
    t.string "location"
    t.string "organizer"
    t.string "source"
    t.string "source_url"
    t.date "start_date"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["event_type"], name: "index_events_on_event_type"
    t.index ["location"], name: "index_events_on_location"
    t.index ["source_url"], name: "index_events_on_source_url", unique: true
    t.index ["start_date"], name: "index_events_on_start_date"
  end

  create_table "external_catalogs", force: :cascade do |t|
    t.boolean "adult", default: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "external_id", null: false
    t.string "genres"
    t.string "media_type"
    t.json "metadata", default: {}
    t.string "original_language"
    t.float "popularity"
    t.string "poster_url"
    t.date "release_date"
    t.string "source", null: false
    t.string "status"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.float "vote_average"
    t.integer "vote_count"
    t.index ["media_type"], name: "index_external_catalogs_on_media_type"
    t.index ["release_date"], name: "index_external_catalogs_on_release_date"
    t.index ["source", "external_id"], name: "index_external_catalogs_on_source_and_external_id", unique: true
    t.index ["source"], name: "index_external_catalogs_on_source"
  end

  create_table "news_articles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "link", null: false
    t.datetime "pub_date"
    t.string "query_used"
    t.string "source"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["link"], name: "index_news_articles_on_link", unique: true
    t.index ["pub_date"], name: "index_news_articles_on_pub_date"
    t.index ["source"], name: "index_news_articles_on_source"
  end

  create_table "profile_snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "followers_count"
    t.bigint "following_count"
    t.bigint "posts_count"
    t.datetime "recorded_at", null: false
    t.integer "social_profile_id", null: false
    t.boolean "source_degraded", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["recorded_at"], name: "index_profile_snapshots_on_recorded_at"
    t.index ["social_profile_id"], name: "index_profile_snapshots_on_social_profile_id"
  end

  create_table "social_posts", force: :cascade do |t|
    t.bigint "comments_count"
    t.text "content"
    t.datetime "created_at", null: false
    t.bigint "likes_count"
    t.json "media_urls", default: []
    t.string "platform_post_id", null: false
    t.string "post_type", null: false
    t.datetime "posted_at"
    t.bigint "shares_count"
    t.string "shortcode"
    t.integer "social_profile_id", null: false
    t.string "thumbnail_url"
    t.datetime "updated_at", null: false
    t.string "video_url"
    t.bigint "views_count"
    t.index ["post_type"], name: "index_social_posts_on_post_type"
    t.index ["posted_at"], name: "index_social_posts_on_posted_at"
    t.index ["social_profile_id", "platform_post_id"], name: "index_social_posts_on_social_profile_id_and_platform_post_id", unique: true
    t.index ["social_profile_id"], name: "index_social_posts_on_social_profile_id"
  end

  create_table "social_profiles", force: :cascade do |t|
    t.string "avatar_url"
    t.text "bio"
    t.string "collection_status", default: "pending"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.bigint "followers_count"
    t.bigint "following_count"
    t.boolean "is_private", default: false
    t.datetime "last_collected_at"
    t.string "platform", null: false
    t.string "platform_url"
    t.string "platform_user_id", null: false
    t.string "platform_username", null: false
    t.integer "posts_count", default: 0, null: false
    t.string "profile_url"
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false
    t.index ["platform", "platform_user_id"], name: "index_social_profiles_on_platform_and_platform_user_id", unique: true
    t.index ["platform"], name: "index_social_profiles_on_platform"
    t.index ["verified"], name: "index_social_profiles_on_verified"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", limit: 4, null: false
    t.datetime "created_at", null: false
    t.binary "key", limit: 1024, null: false
    t.integer "key_hash", limit: 8, null: false
    t.binary "value", limit: 536870912, null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  add_foreign_key "chat_messages", "conversations"
  add_foreign_key "discovered_profiles", "social_profiles", column: "source_profile_id"
  add_foreign_key "profile_snapshots", "social_profiles"
  add_foreign_key "social_posts", "social_profiles"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
