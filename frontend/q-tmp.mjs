import { PGlite } from "@electric-sql/pglite";

const db = await PGlite.create(process.argv[2]);
const r = await db.query(
  "SELECT block_number, log_index, name, args, what, sub FROM events ORDER BY block_number, log_index",
);
for (const row of r.rows)
  console.log(
    row.block_number,
    row.log_index,
    row.name,
    JSON.stringify(row.args),
    "=>",
    row.what,
    row.sub,
  );
