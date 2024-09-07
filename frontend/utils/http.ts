export async function apiFetch(path: string, options: RequestInit): Promise<Response> {
    const headers = new Headers(options.headers);
    if (!headers.has("content-type") && options.method === "POST") {
        headers.set("content-type", "application/json")
    }

    const result = await fetch(apiUrl(path), {
        ...options,
        headers,
    })
    if (!result.ok) throw new Error(`api fetch failed (status ${result.status}): ${await result.text()}`)
    return result
}

export function apiUrl(path: string): string {
    if (!path.startsWith("/")) throw new Error("Path must start with '/'")

    const origin = (process.env.NODE_ENV !== "production" && process.env.NEXT_PUBLIC_BACKEND_URL !== undefined) ? process.env.NEXT_PUBLIC_BACKEND_URL : ""
    return origin + path
}