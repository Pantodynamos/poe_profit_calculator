const POE_API_BASE = 'https://poe.ninja/poe1/api/economy/';

const ALLOWED_PATHS = new Set([
  'leagues',
  'exchange/current/overview',
  'stash/current/item/overview',
  'stash/current/currency/overview',
]);

export async function onRequestGet({ request }) {
  const incomingUrl = new URL(request.url);

  // Extract the endpoint after /api/poe/
  const path = incomingUrl.pathname.replace(/^\/api\/poe\/?/, '');

  if (!ALLOWED_PATHS.has(path)) {
    return Response.json(
      {
        error: 'Endpoint not allowed',
        receivedPath: path,
      },
      { status: 404 }
    );
  }

  // Build the upstream URL and preserve all query parameters.
  const upstreamUrl = new URL(path, POE_API_BASE);
  upstreamUrl.search = incomingUrl.search;

  try {
    const upstream = await fetch(upstreamUrl.toString(), {
      headers: {
        Accept: 'application/json',
        'User-Agent': 'PathOfInvest/1.0',
      },
      cf: {
        cacheEverything: true,
        cacheTtl: 300,
      },
    });

    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        'Content-Type':
          upstream.headers.get('Content-Type') || 'application/json',
        'Cache-Control': upstream.ok
          ? 'public, max-age=300'
          : 'no-store',
        'X-Content-Type-Options': 'nosniff',
      },
    });
  } catch (error) {
    return Response.json(
      { error: 'Unable to reach poe.ninja' },
      {
        status: 502,
        headers: { 'Cache-Control': 'no-store' },
      }
    );
  }
}