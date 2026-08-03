process.env.ARCHIVE_BUCKET = "test-archive-bucket";

const mockSend = jest.fn();

jest.mock("@aws-sdk/client-s3", () => ({
  S3Client: jest.fn().mockImplementation(() => ({
    send: mockSend,
  })),
  CopyObjectCommand: jest.fn().mockImplementation((input: Record<string, unknown>) => input),
}));

import { CopyObjectCommand } from "@aws-sdk/client-s3";
import { S3Event } from "aws-lambda";
import { format } from "date-fns";
import { handler } from "../main/index";

function buildEvent(key: string): S3Event {
  return {
    Records: [
      {
        s3: {
          bucket: { name: "test-primary-bucket" },
          object: { key },
        },
      },
    ],
  } as S3Event;
}

function buildMultiEvent(keys: string[]): S3Event {
  return {
    Records: keys.map((key) => ({
      s3: {
        bucket: { name: "test-primary-bucket" },
        object: { key },
      },
    })),
  } as S3Event;
}

function lastCopyInput(): Record<string, unknown> {
  return (CopyObjectCommand as unknown as jest.Mock).mock.calls.at(-1)[0];
}

describe("archive Lambda handler", () => {
  beforeEach(() => {
    mockSend.mockReset();
    mockSend.mockResolvedValue({});
    (CopyObjectCommand as unknown as jest.Mock).mockClear();
    jest.restoreAllMocks();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe("key parsing — happy path", () => {
    it("valid key with extension constructs archive key and copies with KMS", async () => {
      jest.useFakeTimers();
      jest.setSystemTime(new Date("2026-01-15T14:30:22.000Z"));
      const datetime = format(new Date(), "yyyyMMdd-HHmmss");

      await handler(
        buildEvent("test/acme-mutual/workday/general-ledger/monthly/report.csv")
      );

      expect(mockSend).toHaveBeenCalledTimes(1);
      const input = lastCopyInput();
      expect(input.Key).toBe(
        `test/monthly/acme-mutual/workday/general-ledger/report_${datetime}.csv`
      );
      expect(input.CopySource).toBe(
        "test-primary-bucket/test/acme-mutual/workday/general-ledger/monthly/report.csv"
      );
      expect(input.ServerSideEncryption).toBe("aws:kms");
      expect(input.Bucket).toBe("test-archive-bucket");
    });

    it("valid key without extension constructs archive key with no trailing dot", async () => {
      jest.useFakeTimers();
      jest.setSystemTime(new Date("2026-01-15T14:30:22.000Z"));
      const datetime = format(new Date(), "yyyyMMdd-HHmmss");

      await handler(
        buildEvent("production/acme-mutual/workday/claims/daily/datafile")
      );

      expect(mockSend).toHaveBeenCalledTimes(1);
      expect(lastCopyInput().Key).toBe(
        `production/daily/acme-mutual/workday/claims/datafile_${datetime}`
      );
      expect(String(lastCopyInput().Key)).not.toMatch(/\.$/);
    });

    it("production environment routes correctly", async () => {
      await handler(
        buildEvent("production/carrier1/partner1/transfer1/annual/file.txt")
      );

      expect(mockSend).toHaveBeenCalledTimes(1);
      expect(String(lastCopyInput().Key)).toMatch(/^production\/annual\//);
    });
  });

  describe("frequency routing", () => {
    const frequencies = [
      "daily",
      "weekly",
      "monthly",
      "quarterly",
      "semi-annual",
      "annual",
    ] as const;

    it.each(frequencies)(
      "routes frequency '%s' to second archive path segment",
      async (frequency) => {
        await handler(
          buildEvent(`test/carrier/partner/transfer/${frequency}/file.txt`)
        );

        expect(mockSend).toHaveBeenCalledTimes(1);
        const segments = String(lastCopyInput().Key).split("/");
        expect(segments[1]).toBe(frequency);
      }
    );
  });

  describe("key structure validation", () => {
    it("key with fewer than 6 parts logs error and skips S3 copy", async () => {
      const errorSpy = jest.spyOn(console, "error").mockImplementation(() => {});

      await handler(
        buildEvent("test/acme-mutual/workday/general-ledger/report.csv")
      );

      expect(errorSpy).toHaveBeenCalledWith(
        expect.stringContaining("Unexpected key structure")
      );
      expect(mockSend).not.toHaveBeenCalled();
    });

    it("key with exactly 6 parts calls S3 copy", async () => {
      await handler(
        buildEvent("test/carrier/partner/transfer/daily/file.txt")
      );

      expect(mockSend).toHaveBeenCalledTimes(1);
    });
  });

  describe("frequency validation", () => {
    it("invalid frequency logs error and skips S3 copy", async () => {
      const errorSpy = jest.spyOn(console, "error").mockImplementation(() => {});

      await handler(
        buildEvent("test/acme-mutual/workday/general-ledger/hourly/file.txt")
      );

      expect(errorSpy).toHaveBeenCalledWith(
        expect.stringContaining("Invalid frequency")
      );
      expect(mockSend).not.toHaveBeenCalled();
    });
  });

  describe("error handling", () => {
    it("S3 copy failure for a single record logs and resolves", async () => {
      const errorSpy = jest.spyOn(console, "error").mockImplementation(() => {});
      mockSend.mockRejectedValue(new Error("S3 error"));

      await expect(
        handler(buildEvent("test/carrier/partner/transfer/daily/file.txt"))
      ).resolves.toBeUndefined();

      expect(errorSpy).toHaveBeenCalled();
    });

    it("multiple records with partial failure still copies valid record", async () => {
      await expect(
        handler(
          buildMultiEvent([
            "test/carrier/partner/transfer/hourly/bad.txt",
            "test/carrier/partner/transfer/daily/good.txt",
          ])
        )
      ).resolves.toBeUndefined();

      expect(mockSend).toHaveBeenCalledTimes(1);
      expect(String(lastCopyInput().Key)).toMatch(/^test\/daily\//);
    });

    it("multiple valid records each trigger a copy", async () => {
      await handler(
        buildMultiEvent([
          "test/c1/p1/t1/daily/a.txt",
          "test/c1/p1/t1/weekly/b.txt",
          "test/c1/p1/t1/monthly/c.txt",
        ])
      );

      expect(mockSend).toHaveBeenCalledTimes(3);
    });
  });

  describe("URL decoding", () => {
    it("decodes + in key to space in CopySource", async () => {
      await handler(
        buildEvent(
          "test/acme-mutual/workday/general-ledger/monthly/file+name.csv"
        )
      );

      expect(mockSend).toHaveBeenCalledTimes(1);
      expect(lastCopyInput().CopySource).toBe(
        "test-primary-bucket/test/acme-mutual/workday/general-ledger/monthly/file name.csv"
      );
      expect(String(lastCopyInput().CopySource)).not.toContain("+");
      expect(String(lastCopyInput().Key)).toContain("file name_");
    });
  });

  describe("datetime suffix", () => {
    it("uses yyyyMMdd-HHmmss and shares one timestamp across records", async () => {
      jest.useFakeTimers();
      jest.setSystemTime(new Date("2026-01-15T14:30:22.000Z"));
      const expectedDatetime = format(new Date(), "yyyyMMdd-HHmmss");
      expect(expectedDatetime).toMatch(/^\d{8}-\d{6}$/);

      await handler(
        buildMultiEvent([
          "test/c1/p1/t1/daily/one.txt",
          "test/c1/p1/t1/weekly/two.txt",
        ])
      );

      expect(mockSend).toHaveBeenCalledTimes(2);
      const keys = (CopyObjectCommand as unknown as jest.Mock).mock.calls.map(
        (call: [Record<string, unknown>]) => String(call[0].Key)
      );
      expect(keys[0]).toContain(`_${expectedDatetime}.txt`);
      expect(keys[1]).toContain(`_${expectedDatetime}.txt`);
      const datetimes = keys.map((key: string) => {
        const match = key.match(/_(\d{8}-\d{6})\./);
        return match?.[1];
      });
      expect(datetimes[0]).toBe(datetimes[1]);
      expect(datetimes[0]).toBe(expectedDatetime);
    });
  });
});
