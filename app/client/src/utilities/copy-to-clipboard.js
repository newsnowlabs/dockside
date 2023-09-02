const copyToClipboardLegacy = text => {
   const copyTextArea = document.createElement('textarea');

   copyTextArea.value = text;
   document.body.appendChild(copyTextArea);

   copyTextArea.select();
   document.execCommand('copy');

   document.body.removeChild(copyTextArea);
};

export default async function copyToClipboard(text) {
   try {
     await navigator.clipboard.writeText(text);
     console.log("Text copied to clipboard successfully!");
   } catch (error) {
     console.error("Unable to copy text to clipboard using navigator.clipboard.writeText; using legacy method", error);
     copyToClipboardLegacy(text);
   }
 }
