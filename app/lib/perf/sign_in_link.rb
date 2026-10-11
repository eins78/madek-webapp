# Sign-in link for the login menu (anonymous pages), see MADEK_PERF_SIGN_IN_RETURN_TO
# in app/views/application/_login_menu.haml.
#   path: return-to is the request path without query (one sign-in URL per page)
#   none: no return-to at all (one sign-in URL in total)
# app/javascript/perf/sign-in-return-to.js adds the full current URL when the link is followed.
module Perf
  module SignInLink
    def self.for(request, params)
      lang = params[:lang].nil? ? '' : "lang=#{CGI.escape(params[:lang])}"
      href =
        if MadekPerf.value(:sign_in_return_to, nil).to_s.strip.downcase == 'none'
          '/auth/sign-in' + (lang.empty? ? '' : "?#{lang}")
        else
          "/auth/sign-in?return-to=#{CGI.escape(request.path)}" + (lang.empty? ? '' : "&#{lang}")
        end
      { href: href, rel: 'nofollow', data: { 'sign-in-return-to' => true } }
    end
  end
end
