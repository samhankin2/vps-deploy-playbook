/*
 * Runtime configuration for the frontend.
 *
 * The GitHub Pages workflow REWRITES this file at deploy time from the
 * repository variable API_BASE_URL, so the API address is changed in one
 * place (Settings > Secrets and variables > Actions > Variables) and never in
 * code. The value below is only the local/no-config fallback.
 *
 * Leave it empty when the frontend and API are served by the same app.
 */
window.APP_API_BASE = "";
