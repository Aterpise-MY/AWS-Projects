import axios from 'axios';

window.axios = axios;
window.axios.defaults.headers.common['X-Requested-With'] = 'XMLHttpRequest';

const token = document.head.querySelector('meta[name="csrf-token"]');

if (token) {
    window.axios.defaults.headers.common['X-CSRF-TOKEN'] = token.content;
}

// Confirm destructive actions. Nothing heavier is needed: the UI is
// server-rendered Blade, so there is no client-side router or state store to
// keep in sync.
document.addEventListener('submit', (event) => {
    const form = event.target;

    if (form instanceof HTMLFormElement && form.querySelector('input[name="_method"][value="DELETE"]')) {
        if (!window.confirm('Delete this permanently?')) {
            event.preventDefault();
        }
    }
});
