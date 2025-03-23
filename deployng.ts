import * as path from "node:path";

const redisHost = Deno.env.get("REDIS_HOST")!;
const redisPort = Deno.env.get("REDIS_PORT")!;
const redisUser = Deno.env.get("REDIS_USER")!;
const redisPassword = Deno.env.get("REDIS_PASSWORD")!;

// run tls proxy
const redisListener = Deno.listen({ port: 6379 });
(async () => {
    for await (const conn of redisListener) {
        (async () => {
            const backend = await Deno.connectTls({
                hostname: redisHost,
                port: parseInt(redisPort),
            });
            await Promise.all([
                conn.readable.pipeTo(backend.writable),
                backend.readable.pipeTo(conn.writable)
            ]);
        })().catch(e => {
            console.error(e);
            conn.close();
        })
    }
})();

const erlRoot = path.join(import.meta.dirname!, "erlang");
const erl = await Deno.readTextFile(path.join(erlRoot, "bin/erl"));
await Deno.writeTextFile(path.join(erlRoot, "bin/erl"), erl.replaceAll(
    "/usr/lib/erlang",
    erlRoot,
));

const proc = new Deno.Command("./build/erlang-shipment/entrypoint.sh", {
    args: ["run"],
    env: {
        LISTENERS: "http:8910",
        REDIS_HOST: "127.0.0.1",
        REDIS_PORT: "6379",
        REDIS_USER: redisUser,
        REDIS_PASSWORD: redisPassword,
        PATH: `${erlRoot}/bin:${Deno.env.get("PATH")}`,
    },
    stdin: "null",
    stdout: "inherit",
    stderr: "inherit",
}).spawn();

let exitCode: number | undefined = undefined;
proc.status.then(status => {
    console.log("Process exited with status", status);
    exitCode = status.code;
});

while (true) {
    try {
        const conn = await Deno.connect({ hostname: "127.0.0.1", port: 8910 });
        conn.close();
        break;
    } catch {
        // wait
    }
    await new Promise(resolve => setTimeout(resolve, 10));
}

Deno.serve(req => {
    if (exitCode !== undefined) {
        return new Response("Backend exited with code " + exitCode, { status: 503 });
    }

    const url = new URL(req.url);
    return fetch(`http://127.0.0.1:8910${url.pathname}${url.search}`, {
        method: req.method,
        headers: req.headers,
        body: req.body,
    });
});
