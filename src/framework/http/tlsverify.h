/*
 * BackpackOT: certificate checks for every https:// and wss:// connection.
 *
 * Security finding SGM-5 (docs/security/PRE_TEST_SECURITY_AUDIT.md, section 7):
 * the stock code set verify_peer and then installed a verify callback that
 * returned true for every certificate, so anyone on the network path (rogue
 * Wi-Fi, a poisoned DNS answer) could answer in backpackot.com's name and hand
 * the updater any file, the replacement exe included.
 *
 * Now every TLS connection
 *   - uses one client context, built by the first connection and never freed;
 *   - trusts the certificates in the Windows "ROOT" store that Windows trusts
 *     for server authentication, plus ISRG Root X1 and X2 built in below;
 *   - requires a certificate that is valid for the host of the URL being
 *     requested (boost::asio::ssl::host_name_verification).
 *
 * Why roots are built in: Windows adds most roots to its store on demand, the
 * first time its own CryptoAPI meets them. A fresh PC whose browser has its own
 * root store may never have fetched ISRG Root X1, the root backpackot.com's
 * Let's Encrypt chain ends at. OpenSSL cannot trigger that download, so without
 * the built-in copies such a PC could never update.
 *
 * Why not set_default_verify_paths() on Windows: in this vcpkg build it reads
 * C:\vcpkg\packages\openssl_x64-windows-static\cert.pem and certs\, a folder
 * any local user can create (the CVE-2019-1552 class), plus the SSL_CERT_FILE
 * and SSL_CERT_DIR variables. On Windows the system store is the trust store.
 *
 * Header only, with no framework dependencies, so a test can compile exactly
 * this code (docs/client-launcher/STATUS.md, release 1346).
 */

#ifndef FRAMEWORK_HTTP_TLSVERIFY_H
#define FRAMEWORK_HTTP_TLSVERIFY_H

#ifndef __EMSCRIPTEN__

#include <boost/asio/ssl.hpp>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
// Windows SDKs before WINCRYPT_USE_SYMBOL_PREFIX define these as macros;
// OpenSSL uses the same names for types.
#undef X509_NAME
#undef X509_EXTENSIONS
#undef PKCS7_ISSUER_AND_SERIAL
#undef PKCS7_SIGNER_INFO
#undef OCSP_REQUEST
#undef OCSP_RESPONSE
#ifdef _MSC_VER
#pragma comment(lib, "crypt32.lib")
#endif
#endif

namespace tlsverify {

// What a trust store was built from (for the client log and for tests).
struct Stats {
    bool systemStoreOpened = false;
    int systemSeen = 0;          // certificates in the Windows ROOT store
    int systemAdded = 0;         // of those, trusted here
    int systemNotForServers = 0; // Windows does not trust them for server authentication
    int systemUnreadable = 0;    // OpenSSL could not read them
    int builtinAdded = 0;        // of detail::kBuiltinRoots
};

namespace detail {

struct BuiltinRoot {
    const char* name;
    const char* sha256; // of the DER, lower-case hex
    const char* pem;
};

// The Let's Encrypt roots. Copied from Mozilla's root store (Node 20
// tls.rootCertificates) and byte-identical to the copies in the Windows store
// of the build PC. A copy whose SHA-256 does not match is not loaded.
inline const BuiltinRoot kBuiltinRoots[] = {
    { "ISRG Root X1 (RSA 4096, valid until 2035-06-04)",
      "96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6",
      "-----BEGIN CERTIFICATE-----\n"
      "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\n"
      "-----END CERTIFICATE-----\n" },
    { "ISRG Root X2 (ECDSA P-384, valid until 2040-09-17)",
      "69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470",
      "-----BEGIN CERTIFICATE-----\n"
      "MIICGzCCAaGgAwIBAgIQQdKd0XLq7qeAwSxs6S+HUjAKBggqhkjOPQQDAzBPMQsw\n"
      "CQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2gg\n"
      "R3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMjAeFw0yMDA5MDQwMDAwMDBaFw00\n"
      "MDA5MTcxNjAwMDBaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBT\n"
      "ZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgyMHYw\n"
      "EAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0HttwW\n"
      "+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9\n"
      "ItgKbppbd9/w+kHsOdx1ymgHDB/qo0IwQDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0T\n"
      "AQH/BAUwAwEB/zAdBgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwCgYIKoZI\n"
      "zj0EAwMDaAAwZQIwe3lORlCEwkSHRhtFcP9Ymd70/aTSVaYgLXTWNLxBo1BfASdW\n"
      "tL4ndQavEi51mI38AjEAi/V3bNTIZargCyzuFJ0nN6T5U6VR5CmD1/iQMVtCnwr1\n"
      "/q4AaOeMSQ+2b1tbFfLn\n"
      "-----END CERTIFICATE-----\n" },
};

inline std::string toHex(const unsigned char* data, unsigned int size)
{
    static const char digits[] = "0123456789abcdef";
    std::string out;
    out.reserve(size * 2);
    for (unsigned int i = 0; i < size; ++i) {
        out += digits[data[i] >> 4];
        out += digits[data[i] & 15];
    }
    return out;
}

inline int addBuiltinRoots(X509_STORE* store)
{
    int added = 0;
    for (const BuiltinRoot& root : kBuiltinRoots) {
        BIO* bio = BIO_new_mem_buf(root.pem, -1);
        X509* cert = bio ? PEM_read_bio_X509(bio, nullptr, nullptr, nullptr) : nullptr;
        if (bio)
            BIO_free(bio);
        if (!cert)
            continue;
        unsigned char md[EVP_MAX_MD_SIZE];
        unsigned int mdSize = 0;
        if (X509_digest(cert, EVP_sha256(), md, &mdSize) == 1 && toHex(md, mdSize) == root.sha256 &&
            X509_STORE_add_cert(store, cert) == 1)
            ++added;
        X509_free(cert);
    }
    return added;
}

#ifdef _WIN32
// 1: Windows trusts the certificate for server authentication, 0: it does not,
// -1: nothing is said at this level. flags picks the level: the property set in
// the store (an owner or policy can disable a root for some purposes) or the
// certificate's own extension. Read the way CPython's ssl.enum_certificates
// reads it.
inline int serverAuthUse(PCCERT_CONTEXT cert, DWORD flags)
{
    const DWORD notFound = static_cast<DWORD>(CRYPT_E_NOT_FOUND);
    DWORD size = 0;
    if (!CertGetEnhancedKeyUsage(cert, flags, nullptr, &size))
        return GetLastError() == notFound ? -1 : 0;
    if (size < sizeof(CERT_ENHKEY_USAGE))
        size = sizeof(CERT_ENHKEY_USAGE);
    std::vector<unsigned char> buffer(size);
    PCERT_ENHKEY_USAGE usage = reinterpret_cast<PCERT_ENHKEY_USAGE>(buffer.data());
    SetLastError(0);
    if (!CertGetEnhancedKeyUsage(cert, flags, usage, &size))
        return GetLastError() == notFound ? -1 : 0;
    if (usage->cUsageIdentifier == 0) // good for every use (CRYPT_E_NOT_FOUND) or for none
        return GetLastError() == notFound ? -1 : 0;
    for (DWORD i = 0; i < usage->cUsageIdentifier; ++i) {
        const char* oid = usage->rgpszUsageIdentifier[i];
        if (oid && std::strcmp(oid, szOID_PKIX_KP_SERVER_AUTH) == 0)
            return 1;
    }
    return 0;
}

inline bool trustedForServers(PCCERT_CONTEXT cert)
{
    const int property = serverAuthUse(cert, CERT_FIND_PROP_ONLY_ENHKEY_USAGE_FLAG);
    if (property >= 0)
        return property == 1;
    return serverAuthUse(cert, CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG) != 0;
}

// The current user's view of "ROOT" also holds the machine's roots
// (LocalMachine Root, AuthRoot, Enterprise and Group Policy).
inline void addWindowsRoots(X509_STORE* store, Stats& stats)
{
    HCERTSTORE system = CertOpenSystemStoreW(0, L"ROOT");
    if (!system)
        return;
    stats.systemStoreOpened = true;
    PCCERT_CONTEXT cert = nullptr;
    while ((cert = CertEnumCertificatesInStore(system, cert)) != nullptr) {
        ++stats.systemSeen;
        if (!trustedForServers(cert)) {
            ++stats.systemNotForServers;
            continue;
        }
        const unsigned char* der = cert->pbCertEncoded;
        X509* x509 = (cert->dwCertEncodingType & X509_ASN_ENCODING) && der
            ? d2i_X509(nullptr, &der, static_cast<long>(cert->cbCertEncoded)) : nullptr;
        if (!x509) {
            ++stats.systemUnreadable;
            continue;
        }
        if (X509_STORE_add_cert(store, x509) == 1) // a duplicate is not an error (OpenSSL 1.1.1+)
            ++stats.systemAdded;
        else
            ++stats.systemUnreadable;
        X509_free(x509);
    }
    CertCloseStore(system, 0);
}
#endif

} // namespace detail

// A TLS 1.2 client context that verifies peers against: the system roots
// (Windows: the ROOT store as above; elsewhere OpenSSL's default paths, which
// are root-owned system folders there) and/or the built-in roots. The client
// uses one shared instance (clientContext); tests build their own.
inline std::shared_ptr<boost::asio::ssl::context> makeContext(bool systemRoots, bool builtinRoots, Stats& stats)
{
    auto context = std::make_shared<boost::asio::ssl::context>(boost::asio::ssl::context::tlsv12_client);
    context->set_verify_mode(boost::asio::ssl::verify_peer);
    X509_STORE* store = SSL_CTX_get_cert_store(context->native_handle());
    if (systemRoots) {
#ifdef _WIN32
        detail::addWindowsRoots(store, stats);
#else
        boost::system::error_code ignored;
        context->set_default_verify_paths(ignored);
        stats.systemStoreOpened = !ignored;
#endif
    }
    if (builtinRoots)
        stats.builtinAdded = detail::addBuiltinRoots(store);
    ERR_clear_error(); // leave nothing in this thread's error queue for the first handshake
    return context;
}

namespace detail {

struct Shared {
    std::shared_ptr<boost::asio::ssl::context> context;
    Stats stats;
};

inline Shared& shared()
{
    // Built by the first connection (one thread does it, the rest wait) and
    // never freed: OpenSSL cleans itself up at exit and must not meet a
    // context that outlives it.
    static Shared* instance = [] {
        Shared* s = new Shared();
        s->context = makeContext(true, true, s->stats);
        return s;
    }();
    return *instance;
}

} // namespace detail

// The context every https:// and wss:// connection of the client uses.
inline std::shared_ptr<boost::asio::ssl::context> clientContext() { return detail::shared().context; }
inline const Stats& clientStats() { return detail::shared().stats; }

// True exactly once per process: the first connection says what it trusts.
inline bool firstUse()
{
    static std::atomic<bool> used{ false };
    return !used.exchange(true);
}

// The built-in roots loaded and, on Windows, the system store was read.
inline bool healthy(const Stats& stats)
{
    const int builtinCount = static_cast<int>(sizeof(detail::kBuiltinRoots) / sizeof(detail::kBuiltinRoots[0]));
    return stats.builtinAdded == builtinCount && stats.systemStoreOpened;
}

inline std::string describe(const Stats& stats)
{
    char line[320];
    std::snprintf(line, sizeof(line),
                  "TLS: server certificates are checked. Trusted roots: %d from the Windows store%s "
                  "(%d seen, %d not trusted there for servers, %d unreadable), %d built in.",
                  stats.systemAdded, stats.systemStoreOpened ? "" : " (store could not be opened)",
                  stats.systemSeen, stats.systemNotForServers, stats.systemUnreadable, stats.builtinAdded);
    return line;
}

// Accepts the peer only if its chain verified AND its certificate is valid for
// `host` (boost::asio::ssl::host_name_verification: a DNS name, or an IP
// address against the certificate's IP entries). A wrong name is recorded as
// X509_V_ERR_HOSTNAME_MISMATCH, so the log says "hostname mismatch" instead of
// "unspecified certificate verification error".
class HostCheck
{
public:
    explicit HostCheck(const std::string& host) : m_check(host) {}

    bool operator()(bool preverified, boost::asio::ssl::verify_context& ctx) const
    {
        const bool ok = m_check(preverified, ctx);
        if (!ok && preverified)
            X509_STORE_CTX_set_error(ctx.native_handle(), X509_V_ERR_HOSTNAME_MISMATCH);
        return ok;
    }

private:
    boost::asio::ssl::host_name_verification m_check;
};

// url starts with "<scheme>://" in any letter case (parseURI lower-cases the
// scheme before it picks port 443, so the TLS decision must match it).
inline bool hasScheme(const std::string& url, const char* scheme)
{
    const std::string prefix = std::string(scheme) + "://";
    if (url.size() < prefix.size())
        return false;
    for (size_t i = 0; i < prefix.size(); ++i) {
        const char c = url[i];
        const char lower = (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
        if (lower != prefix[i])
            return false;
    }
    return true;
}

// Before the handshake: verify the peer, and for this host.
template <class Stream>
void requireHost(Stream& stream, const std::string& host)
{
    stream.set_verify_mode(boost::asio::ssl::verify_peer);
    stream.set_verify_callback(HostCheck(host));
}

// After a failed handshake: ", <why the certificate was refused>", or "" when
// the certificate was not the problem.
inline std::string refusalSuffix(SSL* ssl)
{
    if (!ssl)
        return std::string();
    const long result = SSL_get_verify_result(ssl);
    if (result == X509_V_OK)
        return std::string();
    return std::string(", ") + X509_verify_cert_error_string(result);
}

} // namespace tlsverify

#endif // __EMSCRIPTEN__

#endif // FRAMEWORK_HTTP_TLSVERIFY_H
