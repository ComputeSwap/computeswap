import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  agentRules: false,
  // PGlite ships a wasm bundle that must stay outside the server bundle
  serverExternalPackages: ["@electric-sql/pglite"],
};

export default nextConfig;
