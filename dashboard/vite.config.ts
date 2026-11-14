import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// In development the console runs on Vite and proxies the API to the
// server (tool/dev.sh, :8080). In production the server serves dist/.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    proxy: {
      '/api': 'http://localhost:8080',
      '/console/v1': 'http://localhost:8080',
    },
  },
})
