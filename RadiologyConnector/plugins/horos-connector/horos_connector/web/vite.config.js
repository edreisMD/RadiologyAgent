import { defineConfig } from 'vite';
export default defineConfig({base:'/',build:{outDir:'build',emptyOutDir:true,chunkSizeWarningLimit:2500},worker:{format:'es'},optimizeDeps:{exclude:['@cornerstonejs/dicom-image-loader']}});
