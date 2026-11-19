// Cloudflare Pages Function: reenvia /api/* hacia el balanceador de AWS.
// Asi el navegador solo habla con el dominio de Cloudflare (mismo origen):
// no hay problemas de CORS entre sitios, de cookies ni de contenido mixto.
//
// Configuracion (Cloudflare Pages -> Settings -> Variables and Secrets):
//   API_ORIGIN = http://<elb-dns>   (la URL que imprime deploy_aws.sh, sin "/" final)
export async function onRequest({ request, env }) {
  const apiOrigin = env.API_ORIGIN?.trim();

  if (!apiOrigin) {
    return new Response(
      JSON.stringify({
        error: { code: "API_ORIGIN_MISSING", message: "API_ORIGIN is not configured" },
      }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const incoming = new URL(request.url);
  const target = new URL(incoming.pathname + incoming.search, apiOrigin);

  // Conserva metodo, cabeceras (incluida la cookie de sesion) y cuerpo
  return fetch(new Request(target, request));
}
