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
        const wxSrc = button.dataset.wx;
        const apSrc = button.dataset.ap;
        
        amountButtons.forEach(btn => btn.classList.remove('selected'));
        button.classList.add('selected');
        
        if (wxSrc && apSrc) {
            loadImage(wxQrImg, wxSrc);
            loadImage(apQrImg, apSrc);
            qrSection.classList.add('visible');
        }
    }
    
    amountButtons.forEach(button => {
        button.addEventListener('click', () => selectAmount(button));
    });
    
    [wxQrImg, apQrImg].forEach(img => {
        img.addEventListener('click', () => {
            if (img.src) {
                window.open(img.src, '_blank');
            }
        });
    });
})();
