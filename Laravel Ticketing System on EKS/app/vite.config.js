import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';

export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/css/app.css', 'resources/js/app.js'],
            refresh: true,
        }),
    ],
    build: {
        // Assets are compiled in the `assets` Docker stage and copied into the
        // runtime image at /var/www/public/build. Nothing is built at runtime.
        outDir: 'public/build',
        emptyOutDir: true,
        manifest: true,
    },
});
