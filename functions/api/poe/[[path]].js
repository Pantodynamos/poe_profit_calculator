
const POE_API_BASE = 'https://poe.ninja/poe1/api/economy/';

export async function onRequestGet(context) {
  const { request, params } = context;
  const path = Array.isArray(params.path)
    ? params.path.join('/')
    : params.path || '';

  // Only expose the economy endpoints this application needs.
  const allowedPath =
    path === 'leagues' ||
    /^stash\/current\/(item|currency)\/overview$/.test(path);

  if (!allowedPath) {
    return Response.json(
      { error: 'Endpoint not allowed' },
      { status: 404 }
    );
  }

  const incomingUrl = new URL(request.url);
  const upstreamUrl = new URL(path, POE_API_BASE);
  upstreamUrl.search = incomingUrl.search;

  try {
    const upstream = await fetch(upstreamUrl.toString(), {
      headers: {
        Accept: 'application/json',
        'User-Agent': 'PathOfInvest/1.0 (PoE economy calculator)',
      },
      cf: {
        cacheEverything: true,
        cacheTtl: 300,
      },
    });

    const headers = new Headers({
      'Content-Type':
        upstream.headers.get('Content-Type') || 'application/json',
      'Cache-Control': upstream.ok
        ? 'public, max-age=300'
        : 'no-store',
      'X-Content-Type-Options': 'nosniff',
    });

    return new Response(upstream.body, {
      status: upstream.status,
      headers,
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
