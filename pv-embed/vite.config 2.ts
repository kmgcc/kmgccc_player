import { defineConfig } from 'vite';

export default defineConfig({
  root: 'demo',
  server: {
    port: 5173,
    open: true
  },
  build: {
    outDir: '../dist',
    emptyOutDir: true,
    lib: {
      entry: '../src/main.ts',
      name: 'PVEmbed',
      fileName: 'pv-embed',
      formats: ['es', 'umd']
    },
    rollupOptions: {
      external: ['pixi.js'],
      output: {
        globals: {
          'pixi.js': 'PIXI'
        }
      }
    }
  }
});
