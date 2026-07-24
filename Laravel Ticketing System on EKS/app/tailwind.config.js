import forms from '@tailwindcss/forms';

/** @type {import('tailwindcss').Config} */
export default {
    content: [
        './resources/views/**/*.blade.php',
        './resources/js/**/*.js',
    ],
    theme: {
        extend: {
            colors: {
                priority: {
                    low: '#64748b',
                    normal: '#0ea5e9',
                    high: '#f59e0b',
                    urgent: '#dc2626',
                },
            },
        },
    },
    plugins: [forms],
};
