import { S3Client, CopyObjectCommand } from "@aws-sdk/client-s3";
import { S3Event } from "aws-lambda";
import { format } from "date-fns";

const s3 = new S3Client({});

const VALID_FREQUENCIES = ["daily", "weekly", "monthly", "quarterly", "semi-annual", "annual"];

const ARCHIVE_BUCKET = process.env.ARCHIVE_BUCKET;
if (!ARCHIVE_BUCKET) {
  throw new Error("ARCHIVE_BUCKET environment variable is required");
}

export const handler = async (event: S3Event): Promise<void> => {
  // Shared UTC timestamp for all records in this invocation
  const datetime = format(new Date(), "yyyyMMdd-HHmmss");

  for (const record of event.Records) {
    const sourceBucket = record.s3.bucket.name;
    const sourceKey = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

    try {
      const parts = sourceKey.split("/");

      if (parts.length < 6) {
        console.error(`Unexpected key structure — skipping: ${sourceKey}`);
        continue;
      }

      const [envPath, carrierId, partnerId, transferTypeId, frequency, filename] = parts;

      if (!VALID_FREQUENCIES.includes(frequency)) {
        console.error(`Invalid frequency '${frequency}' in key — skipping: ${sourceKey}`);
        continue;
      }

      // Split filename into basename and extension
      const lastDot = filename.lastIndexOf(".");
      const basename = lastDot > -1 ? filename.slice(0, lastDot) : filename;
      const ext = lastDot > -1 ? filename.slice(lastDot) : "";

      // Construct archive key — frequency moved to second level
      const archiveKey = `${envPath}/${frequency}/${carrierId}/${partnerId}/${transferTypeId}/${basename}_${datetime}${ext}`;

      await s3.send(
        new CopyObjectCommand({
          CopySource: `${sourceBucket}/${sourceKey}`,
          Bucket: ARCHIVE_BUCKET,
          Key: archiveKey,
          ServerSideEncryption: "aws:kms",
        })
      );

      console.log(`Archived: ${sourceKey} → ${archiveKey}`);
    } catch (err) {
      console.error(`Failed to archive ${sourceKey}:`, err);
    }
  }
};
