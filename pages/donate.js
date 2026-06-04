(function() {
    const amountButtons = document.querySelectorAll('.amount-btn');
    const qrSection = document.getElementById('qrSection');
    const wxQrImg = document.getElementById('wxQr');
    const apQrImg = document.getElementById('apQr');

    function loadImage(img, src) {
        img.classList.remove('loaded');
        img.src = src;
        img.onload = () => {
            img.classList.add('loaded');
        };
    }

    function selectAmount(button) {
        const { wx, ap } = button.dataset;

        amountButtons.forEach(btn => btn.classList.remove('selected'));
        button.classList.add('selected');

        if (wx && ap) {
            loadImage(wxQrImg, wx);
            loadImage(apQrImg, ap);
            qrSection.classList.add('visible');
        }
    }

    amountButtons.forEach(button => {
        button.addEventListener('click', event => selectAmount(event.currentTarget));
    });

    if (amountButtons.length > 0) {
        selectAmount(amountButtons[0]);
    }

    [wxQrImg, apQrImg].forEach(img => {
        img.addEventListener('click', () => {
            if (img.src) {
                window.open(img.src, '_blank');
            }
        });
    });
})();
