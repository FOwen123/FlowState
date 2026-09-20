import {
  asBoundedText,
  FetchImplementation,
  isRecord,
  requestJson,
  requireApiKey,
} from "./http";

export type FirecrawlSearchResult = {
  url: string;
  title?: string;
  description?: string;
  markdown?: string;
};

export type FirecrawlScrapeResult = {
  url: string;
  title?: string;
  markdown: string;
};

type FirecrawlClientOptions = {
  apiKey?: string;
  baseUrl?: string;
  fetch?: FetchImplementation;
};

function requirePublicUrl(value: string): string {
  const url = asBoundedText(value, "url", 2_000);
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error("url must be a valid HTTP(S) URL");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("url must use HTTP or HTTPS");
  }
  const host = parsed.hostname.toLowerCase().replace(/\.$/, "");
  if (
    parsed.username ||
    parsed.password ||
    !host.includes(".") ||
    host.includes(":") ||
    /^[\d.]+$/.test(host) ||
    /(^|\.)(localhost|local|internal|test)$/.test(host) ||
    (parsed.port && parsed.port !== "80" && parsed.port !== "443")
  ) {
    throw new Error("url must name a public website without credentials");
  }
  return parsed.toString();
}

function parseSearchResponse(value: unknown): FirecrawlSearchResult[] {
  if (!isRecord(value) || value.success !== true || !isRecord(value.data)) {
    throw new Error("Firecrawl returned an invalid search response");
  }
  const web = value.data.web;
  if (!Array.isArray(web)) {
    return [];
  }
  return web.flatMap((item): FirecrawlSearchResult[] => {
    if (!isRecord(item) || typeof item.url !== "string") {
      return [];
    }
    return [
      {
        url: item.url,
        ...(typeof item.title === "string" ? { title: item.title } : {}),
        ...(typeof item.description === "string"
          ? { description: item.description }
          : {}),
        ...(typeof item.markdown === "string"
          ? { markdown: item.markdown }
          : {}),
      },
    ];
  });
}

function parseScrapeResponse(
  value: unknown,
  requestedUrl: string,
): FirecrawlScrapeResult {
  if (!isRecord(value) || value.success !== true || !isRecord(value.data)) {
    throw new Error("Firecrawl returned an invalid scrape response");
  }
  const markdown = asBoundedText(value.data.markdown, "data.markdown", 100_000);
  const metadata = isRecord(value.data.metadata)
    ? value.data.metadata
    : undefined;
  return {
    url: requestedUrl,
    markdown,
    ...(metadata && typeof metadata.title === "string"
      ? { title: metadata.title }
      : {}),
  };
}

export function createFirecrawlClient(options: FirecrawlClientOptions) {
  const apiKey = requireApiKey(options.apiKey, "Firecrawl");
  const baseUrl = (options.baseUrl ?? "https://api.firecrawl.dev/v2").replace(
    /\/$/,
    "",
  );
  const fetchImplementation = options.fetch ?? globalThis.fetch;

  return {
    async search(query: string, limit = 5): Promise<FirecrawlSearchResult[]> {
      const normalizedQuery = asBoundedText(query, "query", 1_000);
      if (!Number.isInteger(limit) || limit < 1 || limit > 10) {
        throw new Error("limit must be an integer between 1 and 10");
      }
      const response = await requestJson(
        "firecrawl",
        fetchImplementation,
        `${baseUrl}/search`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            query: normalizedQuery,
            limit,
            scrapeOptions: { formats: ["markdown"] },
          }),
        },
      );
      return parseSearchResponse(response);
    },

    async scrape(url: string): Promise<FirecrawlScrapeResult> {
      const normalizedUrl = requirePublicUrl(url);
      const response = await requestJson(
        "firecrawl",
        fetchImplementation,
        `${baseUrl}/scrape`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ url: normalizedUrl, formats: ["markdown"] }),
        },
      );
      return parseScrapeResponse(response, normalizedUrl);
    },
  };
}
