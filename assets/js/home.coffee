---
---

(($) ->
  $animateIn       = $('.animate-in')
  $animateOut      = $('.animate-out')
  animateInOffset  = 100
  animateOutOffset = 0

  windowHeight         = $(window).height()
  windowScrollPosition = $(window).scrollTop()
  bottomScrollPosition = windowHeight + windowScrollPosition

  $animateIn.each (i, element) ->
    if $(element).offset().top + animateInOffset >= bottomScrollPosition
      $(element).addClass 'pre-animate-in'

  $animateOut.each (i, element) ->
    if $(element).offset().top + animateOutOffset >= bottomScrollPosition
      $(element).addClass 'pre-animate-out'

  $(window).scroll (e) ->
    windowHeight         = $(window).height()
    windowScrollPosition = $(window).scrollTop()
    bottomScrollPosition = windowHeight + windowScrollPosition

    $animateIn.each (i, element) ->
      if $(element).offset().top + animateInOffset < bottomScrollPosition
        $(element).removeClass 'pre-animate-in'

    $animateOut.each (i, element) ->
      if $(element).offset().top + animateOutOffset < bottomScrollPosition
        $(element).removeClass 'pre-animate-out'
        
) jQuery
