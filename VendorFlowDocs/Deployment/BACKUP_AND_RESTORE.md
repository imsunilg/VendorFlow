# Backup and restore

Two things hold data: the PostgreSQL database `Vendor_db` and the uploads folder (`Storage:Path`, volume `storage` in compose).

## Backup
```bash
# database (custom format, compressed)
docker compose exec -T db pg_dump -U postgres -Fc Vendor_db > vendorflow-$(date +%F).dump
# uploads
docker run --rm -v vendorflow_storage:/data -v "$PWD":/backup alpine tar czf /backup/storage-$(date +%F).tgz -C /data .
```
Without Docker: `pg_dump -h <host> -U postgres -Fc Vendor_db -f vendorflow.dump` and copy the uploads folder.

Schedule it daily, keep at least 14 copies, store them off the server, and encrypt them (they contain vendor bank details).

## Restore
```bash
docker compose stop api web
docker compose exec -T db psql -U postgres -c 'DROP DATABASE IF EXISTS "Vendor_db"'
docker compose exec -T db psql -U postgres -c 'CREATE DATABASE "Vendor_db"'
docker compose exec -T db pg_restore -U postgres -d Vendor_db --no-owner < vendorflow-YYYY-MM-DD.dump
docker run --rm -v vendorflow_storage:/data -v "$PWD":/backup alpine sh -c "rm -rf /data/* && tar xzf /backup/storage-YYYY-MM-DD.tgz -C /data"
docker compose start api web
```
Then open `/health` and sign in. The API re-applies its function scripts on start, so a restore from an older version of the app is upgraded automatically.

## Test the restore
Every month restore the latest backup into a scratch database (`createdb Vendor_restore_test; pg_restore -d Vendor_restore_test …`) and check a few counts: `select count(*) from vendorflow.purchase_orders;`.

## Point-in-time recovery
For stricter needs enable WAL archiving on PostgreSQL (`archive_mode`, `archive_command`) or use a managed PostgreSQL service with PITR.
