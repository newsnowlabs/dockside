$(document).delegate('.ui-dialog', 'keyup keypress', function(e) {
    var target = e.target;
    var tagName = target.tagName.toLowerCase();

    tagName = (tagName === 'input' && target.type === 'button') ?
        'button' :
        tagName;

    isClickableTag = tagName !== 'textarea' &&
        tagName !== 'select' &&
        tagName !== 'button';

    if (e.which === 13 && isClickableTag) {
        e.preventDefault();

        if (e.type === 'keyup') {
            var el = $(this).find('.modal-footer > button.btn-primary').eq(0).trigger('click');
        }

        return false;
    }
});
