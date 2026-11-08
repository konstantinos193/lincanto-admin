/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: 'res.cloudinary.com',
      },
    ],
  },
  experimental: {
    // Same shared-host reasoning as the other sites: serialize sharp jobs so
    // a cold-cache burst cannot push next-server over its cgroup limit.
    imgOptConcurrency: 1,
    imgOptSequentialRead: true,
    imgOptMaxInputPixels: 40000000,
  },
}

module.exports = nextConfig

