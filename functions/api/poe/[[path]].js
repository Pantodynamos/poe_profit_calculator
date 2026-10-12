
const POE_API_BASE = 'https://poe.ninja/poe1/api/economy/';

export async function onRequestGet({ request }) {
  const incomingUrl = new URL(request.url);
  const path = incomingUrl.pathname.replace(/^\/api\/poe\/?/, '');

  const allowedPath =
    path === 'leagues' ||
    /^exchange\/current\/overview$/.test(path) ||
    /^stash\/current\/item\/overview$/.test(path) ||
    /^stash\/current\/currency\/overview$/.test(path);

  if (!allowedPath) {
    return Response.json(
      { error: 'Endpoint not allowed', path },
      { status: 404 }
    );
  }

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
  } catch {
    return Response.json(
      { error: 'Unable to reach poe.ninja' },
      {
        status: 502,
        headers: { 'Cache-Control': 'no-store' },
      }
    );
  }
}
