/** @type {import('next').NextConfig} */
const nextConfig = {
    output: "export",
    trailingSlash: true,
    distDir: process.env.NODE_ENV === "production" ? "../priv/frontend" : undefined,
    swcMinify: true,
    experimental: {
        missingSuspenseWithCSRBailout: false
    }
};

export default nextConfig;
