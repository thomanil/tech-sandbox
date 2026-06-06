import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // Dev server only. In the shipped build the server serves these assets and the
  // WebSocket from one origin; here Vite is a separate origin (:5173), so proxy
  // /ws to the backend on :8000 to keep the client's same-origin `/ws` URL
  // working unchanged. `ws: true` upgrades the proxied connection to a WebSocket.
  server: {
    proxy: {
      '/ws': { target: 'ws://localhost:8000', ws: true },
    },
  },
})
