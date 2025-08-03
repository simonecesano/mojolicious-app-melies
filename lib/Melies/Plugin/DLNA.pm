package Melies::Plugin::DLNA;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::Loader qw/data_section/;
use Mojo::Util qw/html_unescape/;

sub register {
    my ($self, $app, $conf) = @_;

    my $headers = { "SOAPAction" => '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"', "Content-Type" => "text/xml; charset=utf-8" };

    $app->helper(post_soap => sub {
		     my ($self, $id) = @_;
		     my $soap = data_section(__PACKAGE__, "soap.xml");
		     Mojo::DOM->new(html_unescape $app->ua->post($conf->{url} => $headers => sprintf($soap, $id))->res->dom->at("Result")->content)
		 });
}

1;
__DATA__
@@ soap.xml
<?xml version="1.0"?>
<s:Envelope
  xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
      <ObjectID>%s</ObjectID>
      <BrowseFlag>BrowseDirectChildren</BrowseFlag>
      <Filter>*</Filter>
      <StartingIndex>0</StartingIndex>
      <RequestedCount>0</RequestedCount>
      <SortCriteria></SortCriteria>
    </u:Browse>
  </s:Body>
</s:Envelope>
    
