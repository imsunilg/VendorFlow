-- Bootstrap script: always executed first by DatabaseInitializer (idempotent).
create schema if not exists vendorflow;

create table if not exists vendorflow.schema_migrations (
    script_name text primary key,
    checksum    text        not null,
    applied_at  timestamptz not null default now()
);

-- Returns the stored checksum of a run-once script, or null when it was never applied.
create or replace function vendorflow.fn_migration_checksum(p_script text)
returns text language sql stable as $$
    select checksum from vendorflow.schema_migrations where script_name = p_script;
$$;

-- Records that a run-once script has been applied.
create or replace procedure vendorflow.sp_record_migration(p_script text, p_checksum text)
language sql as $$
    insert into vendorflow.schema_migrations (script_name, checksum)
    values (p_script, p_checksum)
    on conflict (script_name) do update set checksum = excluded.checksum, applied_at = now();
$$;
