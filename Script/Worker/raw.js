export default {
	async fetch(request ,env) {
		try {
			const url = new URL(request.url);
			if (url.pathname !== '/') {
				const token = url.searchParams.get('token');
				if (!env.TOKEN || !token || !(await safeEqual(token, env.TOKEN))) return notFound();
				if (request.method !== 'GET' && request.method !== 'HEAD') return notFound();

				const { GH_NAME, GH_REPO, GH_BRANCH, GH_TOKEN } = env;
				if (!GH_NAME || !GH_REPO || !GH_BRANCH || !GH_TOKEN) return notFound();

				const segs = url.pathname.slice(1).split('/').map(decodeURIComponent);
				if (segs.some(s => !s || s === '.' || s === '..' ||
					/[\/\\\u0000-\u001f\u007f]/.test(s))) return notFound();
				const githubRawUrl = `https://raw.githubusercontent.com/${GH_NAME}/${GH_REPO}/${GH_BRANCH}/` +
					segs.map(encodeURIComponent).join('/');
				const response = await fetch(githubRawUrl, {
					method: request.method,
					headers: { Authorization: `token ${GH_TOKEN}` },
					redirect: 'error'
				});
				if (response.status !== 200) {
					if (response.body) await response.body.cancel();
					return notFound();
				}

				const headers = new Headers({ 'Cache-Control': 'no-store' });
				const contentType = response.headers.get('Content-Type');
				if (contentType) headers.set('Content-Type', contentType);
				return new Response(request.method === 'HEAD' ? null : response.body, {
					status: 200,
					headers
				});
			}

			return new Response(await nginx(), {
				headers: {
					'Content-Type': 'text/html; charset=UTF-8',
				},
			});
		} catch {
			return notFound();
		}
	}
};

async function safeEqual(a, b) {
	const encoder = new TextEncoder();
	const [x, y] = await Promise.all([a, b].map(v => crypto.subtle.digest('SHA-256', encoder.encode(v))));
	return crypto.subtle.timingSafeEqual(x, y);
}

function notFound() {
	return new Response('Not Found', {
		status: 404,
		headers: {
			'Content-Type': 'text/plain; charset=UTF-8',
			'Cache-Control': 'no-store'
		}
	});
}

async function nginx() {
	const text = `
	<!DOCTYPE html>
	<html>
	<head>
	<title>Welcome to nginx!</title>
	<style>
		body {
			width: 35em;
			margin: 0 auto;
			font-family: Tahoma, Verdana, Arial, sans-serif;
		}
	</style>
	</head>
	<body>
	<h1>Welcome to nginx!</h1>
	<p>If you see this page, the nginx web server is successfully installed and
	working. Further configuration is required.</p>

	<p>For online documentation and support please refer to
	<a href="http://nginx.org/">nginx.org</a>.<br/>
	Commercial support is available at
	<a href="http://nginx.com/">nginx.com</a>.</p>

	<p><em>Thank you for using nginx.</em></p>
	</body>
	</html>
	`
	return text ;
}
