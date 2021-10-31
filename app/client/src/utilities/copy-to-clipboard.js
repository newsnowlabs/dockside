const copyToClipboard = text => {
   const copyTextArea = document.createElement('textarea');

   copyTextArea.value = text;
   document.body.appendChild(copyTextArea);

   copyTextArea.select();
   document.execCommand('copy');

   document.body.removeChild(copyTextArea);
};

export default copyToClipboard;
