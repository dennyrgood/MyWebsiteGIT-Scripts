// Add New Entry Form Handler

function initAddForm() {
    document.getElementById('add-form').addEventListener('submit', async function(e) {
        e.preventDefault();
        const form = e.target;
        const submitBtn = form.querySelector('.btn-primary');
        submitBtn.disabled = true;
        submitBtn.textContent = 'Submitting...';

        const formData = new FormData(form);
        const payload = {};
        for (const pair of formData.entries()) {
            payload[pair[0]] = pair[1].trim();
        }

        const requiredFields = FIELD_MAP.filter(f => f.required).map(f => f.key);
        for (const key of requiredFields) {
            if (!payload[key]) {
                const label = FIELD_MAP.find(f => f.key === key).label;
                showMessage(label + ' is a required field.', 'error', 'add-new');
                submitBtn.disabled = false;
                submitBtn.textContent = 'Submit New Entry';
                return;
            }
        }

        try {
            const response = await fetch(BACKEND_URL + '/api/add', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });

            const data = await response.json();

            if (response.ok && data.status === 'success') {
                const msgDiv = document.getElementById('add-new-message');
                msgDiv.textContent = '✓ SUCCESS: ' + data.message + '. Switching to Data View...';
                msgDiv.className = 'message show success';
                msgDiv.style.display = 'block';
                msgDiv.style.opacity = '1';
                msgDiv.style.height = 'auto';
                form.reset();
                setTimeout(() => {
                    openTab('data-view');
                }, 3000);
            } else {
                showBackendError(data, 'add-new');
            }
        } catch (error) {
            showMessage('Network error: ' + error.message, 'error', 'add-new');
        } finally {
            submitBtn.disabled = false;
            submitBtn.textContent = 'Submit New Entry';
        }
    });
}