let started = 0;
window.recordingBar.onState(value => { started = value; });
for (const button of document.querySelectorAll('button')) button.onclick = () => window.recordingBar.control(button.dataset.action);
setInterval(() => { if (!started) return; const seconds = Math.floor((Date.now() - started) / 1000); document.getElementById('time').textContent = `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`; }, 500);
