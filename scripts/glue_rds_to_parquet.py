"""
AWS Glue Python Shell Job (0.0625 DPU)
1. Connects to the private RDS PostgreSQL instance over the Glue VPC Connection using pg8000.
2. Seeds the `orders` table with sample data if it does not already exist (idempotent).
3. Reads the records into a Pandas DataFrame and applies transformations (adds tax calculation & ingestion timestamp).
4. Writes the transformed dataset as Snappy-compressed Parquet to S3 via the free S3 Gateway VPC Endpoint.
"""

import datetime
import sys
from awsglue.utils import getResolvedOptions
import pandas as pd
import pg8000.dbapi

# Read job parameters passed by AWS Glue
args = getResolvedOptions(
    sys.argv,
    [
        "DB_HOST",
        "DB_PORT",
        "DB_NAME",
        "DB_USER",
        "DB_PASS",
        "S3_OUTPUT_PATH",
    ],
)

db_host = args["DB_HOST"]
db_port = int(args["DB_PORT"])
db_name = args["DB_NAME"]
db_user = args["DB_USER"]
db_pass = args["DB_PASS"]
s3_output_path = args["S3_OUTPUT_PATH"]


def seed_and_fetch_orders() -> pd.DataFrame:
    print(f"Connecting to PostgreSQL RDS at {db_host}:{db_port}/{db_name}...")
    conn = pg8000.dbapi.connect(
        user=db_user,
        password=db_pass,
        host=db_host,
        port=db_port,
        database=db_name,
        timeout=30,
    )
    cursor = conn.cursor()

    # 1. Create sample table if it does not exist
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS orders (
            order_id INT PRIMARY KEY,
            customer_name VARCHAR(100) NOT NULL,
            category VARCHAR(50) NOT NULL,
            amount DOUBLE PRECISION NOT NULL,
            order_status VARCHAR(30) NOT NULL,
            created_at VARCHAR(40) NOT NULL
        );
        """
    )

    # 2. Seed sample records idempotently
    sample_rows = [
        (101, "Alice Silva", "Electronics", 1250.00, "COMPLETED", "2026-10-28T10:15:00Z"),
        (102, "Bruno Costa", "Books", 89.90, "COMPLETED", "2026-10-28T11:30:00Z"),
        (103, "Carla Souza", "Home & Office", 430.50, "PROCESSING", "2026-10-28T12:45:00Z"),
        (104, "Diego Lima", "Electronics", 2999.99, "COMPLETED", "2026-10-28T14:20:00Z"),
        (105, "Elena Rocha", "Cloud Services", 540.00, "PENDING", "2026-10-28T15:00:00Z"),
    ]

    for row in sample_rows:
        cursor.execute(
            """
            INSERT INTO orders (order_id, customer_name, category, amount, order_status, created_at)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (order_id) DO UPDATE SET
                amount = EXCLUDED.amount,
                order_status = EXCLUDED.order_status;
            """,
            row,
        )

    conn.commit()
    print(f"Seeded {len(sample_rows)} rows into RDS PostgreSQL `orders` table.")

    # 3. Extract data from RDS
    cursor.execute(
        """
        SELECT order_id, customer_name, category, amount, order_status, created_at
        FROM orders
        ORDER BY order_id;
        """
    )
    rows = cursor.fetchall()
    columns = [desc[0] for desc in cursor.description]

    cursor.close()
    conn.close()

    return pd.DataFrame(rows, columns=columns)


def transform_and_write_parquet(df: pd.DataFrame, output_uri: str) -> None:
    print(f"Extracted {len(df)} records from RDS. Transforming data...")

    # Ensure exact types matching the Glue Data Catalog table definition
    df["order_id"] = df["order_id"].astype("int32")
    df["customer_name"] = df["customer_name"].astype("string")
    df["category"] = df["category"].astype("string")
    df["amount"] = df["amount"].astype("float64")
    df["order_status"] = df["order_status"].astype("string")
    df["amount_with_tax"] = (df["amount"] * 1.10).round(2).astype("float64")
    df["created_at"] = df["created_at"].astype("string")
    df["ingested_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    df["ingested_at_utc"] = df["ingested_at_utc"].astype("string")

    print(f"Writing Snappy Parquet file to {output_uri} via S3 Gateway VPC Endpoint...")
    df.to_parquet(
        output_uri,
        engine="pyarrow",
        compression="snappy",
        index=False,
    )
    print("Successfully wrote Parquet data to S3!")


if __name__ == "__main__":
    orders_df = seed_and_fetch_orders()
    transform_and_write_parquet(orders_df, s3_output_path)
