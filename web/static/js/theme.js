// Theme: Bright (data-theme="light") and Night (data-theme="dark").
// The floating "Dark mode / Light mode" button flips between the two; the
// Account settings select also offers "system", which follows the OS.
(function() {
    const THEME_STORAGE_KEY = 'theme_preference';
    const themeSelect = document.getElementById('theme-select');
    const themeToggle = document.getElementById('theme-toggle');
    const docElement = document.documentElement; // Usually <html>
    const loggedIn = Boolean(window.pxtLoggedIn);

    let mediaQueryListener = null;
    let preference = 'system';

    function applyTheme(theme) {
        if (theme === 'system') {
            const systemPrefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
            docElement.setAttribute('data-theme', systemPrefersDark ? 'dark' : 'light');
        } else {
            docElement.setAttribute('data-theme', theme);
        }
    }

    function storePreference(theme) {
        try {
            localStorage.setItem(THEME_STORAGE_KEY, theme);
        } catch (e) {
            // Private mode or blocked storage: the theme still applies for this page.
        }
    }

    function readStoredPreference() {
        try {
            return localStorage.getItem(THEME_STORAGE_KEY);
        } catch (e) {
            return null;
        }
    }

    function savePreferenceToServer(theme) {
        // Ensure this endpoint exists and is protected
        fetch('/set_theme_preference', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                // CSRF protection for this POST request relies on the SameSite=Lax cookie policy.
            },
            body: JSON.stringify({ theme: theme })
        })
        .then(response => {
            if (!response.ok) {
                console.error('Server responded with an error:', response.status, response.statusText);
                // Try to parse as JSON, but provide a fallback if it's not
                return response.text().then(text => {
                    try {
                        // Attempt to parse as JSON first, as the original code expected JSON error messages
                        const errJson = JSON.parse(text);
                        // Ensure it's an error structure we expect, otherwise treat as a generic error
                        if (errJson && (errJson.message || errJson.error)) {
                           return Promise.reject(errJson);
                        }
                        // If not a structured JSON error, or empty JSON, fall through to generic error
                        throw new Error(`Server error: ${response.status} ${response.statusText}. Response: ${text.substring(0, 100)}`);
                    } catch (e) {
                        // If JSON parsing fails, or it's not our expected error format,
                        // throw an error with the status text and part of the response
                        throw new Error(`Server error: ${response.status} ${response.statusText}. Response: ${text.substring(0, 100)}`);
                    }
                });
            }
            return response.json();
        })
        .then(data => {
            if (data.status !== 'success') {
                console.error('Error saving theme preference:', data.message);
            } else {
                console.log('Theme preference saved to server:', theme);
            }
        })
        .catch(error => console.error('Error saving theme preference:', error));
    }

    function handleAppImageGeometry () {
        const APP_IMG_2X_WIDTH = 128;

        const processImage = (img) => {
            const applyClass = () => {
                const container = img.closest('.app-img');
                if (!container) {
                    return;
                }
                const is2x = img.naturalWidth === APP_IMG_2X_WIDTH;
                // Square panels need their own dot mask and aspect ratio;
                // everything else is the classic 2:1 panel.
                const isSquare = img.naturalWidth > 0 && img.naturalWidth === img.naturalHeight;
                container.classList.toggle('is-2x', is2x);
                container.classList.toggle('is-square', isSquare);
            };
            if (img.complete && img.naturalWidth > 0) {
                applyClass();
            } else {
                img.addEventListener('load', applyClass, { once: true });
            }
        };

        document.querySelectorAll('.app-img img').forEach(processImage);

        const observer = new MutationObserver((mutations) => {
            mutations.forEach((mutation) => {
                mutation.addedNodes.forEach((node) => {
                    if (node.nodeType !== 1) return;
                    if (node.matches('.app-img img')) {
                        processImage(node);
                    } else {
                        node.querySelectorAll('.app-img img').forEach(processImage);
                    }
                });
            });
        });

        observer.observe(document.body, { childList: true, subtree: true });
    }

    function handleSystemThemeChange() {
        if (preference === 'system') {
            applyTheme('system');
        }
    }

    function setupSystemThemeListener() {
        if (mediaQueryListener) { // Remove existing listener if any
            mediaQueryListener.removeEventListener('change', handleSystemThemeChange);
        }
        mediaQueryListener = window.matchMedia('(prefers-color-scheme: dark)');
        mediaQueryListener.addEventListener('change', handleSystemThemeChange);
    }

    function removeSystemThemeListener() {
        if (mediaQueryListener) {
            mediaQueryListener.removeEventListener('change', handleSystemThemeChange);
            mediaQueryListener = null;
        }
    }

    // setPreference applies a new choice everywhere: page, storage, server, controls.
    function setPreference(theme) {
        preference = theme;
        applyTheme(theme);
        storePreference(theme);
        if (loggedIn) {
            savePreferenceToServer(theme); // Save to backend for logged-in user
        }
        if (themeSelect) themeSelect.value = theme;
        if (theme === 'system') {
            setupSystemThemeListener();
        } else {
            removeSystemThemeListener();
        }
    }

    function initTheme() {
        // window.currentUserThemePreference is set in base.html
        preference = readStoredPreference() || window.currentUserThemePreference || 'system';
        applyTheme(preference);
        if (preference === 'system') {
            setupSystemThemeListener();
        }
        if (themeSelect) {
            themeSelect.value = preference;
            themeSelect.addEventListener('change', function() {
                setPreference(this.value);
            });
        }
        if (themeToggle) {
            // The pill always flips what is on screen now, which ends "system".
            themeToggle.addEventListener('click', function() {
                const night = docElement.getAttribute('data-theme') === 'dark';
                setPreference(night ? 'light' : 'dark');
            });
        }
        handleAppImageGeometry();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initTheme);
    } else {
        // DOMContentLoaded has already fired
        initTheme();
    }

})();
