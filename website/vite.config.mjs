import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'

export default defineConfig({
  build: {
    rolldownOptions: {
      input: fileURLToPath(new URL('./src/client.js', import.meta.url)),
      output: {
        entryFileNames: 'client.js',
      },
    },
  },
})
