import {
  createStreamApiClient,
  providerHttpBaseUrlFromServerUrl
} from "./stream-api";

describe("stream-api", () => {
  it("converts websocket provider URLs into HTTP control-plane base URLs", () => {
    expect(
      providerHttpBaseUrlFromServerUrl("ws://127.0.0.1:18800/ws").toString()
    ).toBe("http://127.0.0.1:18800/");
    expect(
      providerHttpBaseUrlFromServerUrl("wss://clawline.app/ws").toString()
    ).toBe("https://clawline.app/");
  });

  it("sends authorized stream create requests to the documented route", async () => {
    const requests: Request[] = [];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return new Response(
          JSON.stringify({
            stream: {
              sessionKey: "agent:main:clawline:user_1:s_created",
              displayName: "Research",
              kind: "custom",
              orderIndex: 3,
              isBuiltIn: false,
              createdAt: 10,
              updatedAt: 10,
              adopted: false
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        );
      }
    });

    const response = await client.createStream({
      displayName: "Research",
      idempotencyKey: "uuid-1",
      serverUrl: "ws://127.0.0.1:18800/ws",
      token: "jwt-token"
    });

    expect(response.stream.displayName).toBe("Research");
    expect(requests).toHaveLength(1);
    expect(requests[0].url).toBe("http://127.0.0.1:18800/api/streams");
    expect(requests[0].method).toBe("POST");
    expect(requests[0].headers.get("Authorization")).toBe("Bearer jwt-token");
    expect(await requests[0].json()).toEqual({
      idempotencyKey: "uuid-1",
      displayName: "Research"
    });
  });

  it("percent-encodes session keys for rename and delete routes", async () => {
    const requests: Request[] = [];
    const client = createStreamApiClient({
      fetchFn: async (input, init) => {
        requests.push(new Request(input, init));
        return new Response(
          JSON.stringify({
            stream: {
              sessionKey: "agent:main:openclaw:user:s_trackable",
              displayName: "Renamed",
              kind: "custom",
              orderIndex: 2,
              isBuiltIn: false,
              createdAt: 10,
              updatedAt: 11,
              adopted: true
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        );
      }
    });

    await client.renameStream({
      displayName: "Renamed",
      serverUrl: "ws://127.0.0.1:18800/ws",
      sessionKey: "agent:main:openclaw:user:s_trackable",
      token: "jwt-token"
    });

    expect(requests[0].url).toBe(
      "http://127.0.0.1:18800/api/streams/agent%3Amain%3Aopenclaw%3Auser%3As_trackable"
    );
  });
});
