#!/usr/bin/env python3

import asyncio
import json
import argparse
import sys

try:
    import nodriver as uc
except ImportError:
    print(json.dumps({"error": "nodriver not installed"}), file=sys.stderr)
    sys.exit(1)

import browser_binary

# Esperas adaptativas (compartilhadas entre profile e posts).
SCROLL_TIMEOUT = 12.0
SCROLL_POLL = 0.25


class NoDataExtractedError(Exception):
    pass


class BlockedPageError(Exception):
    pass


def _is_blocked(page_url, html, dom_text):
    """Detecção de página de login, challenge ou bloqueio.

    Marcadores genéricos de CTA (ex.: "sign up") NÃO são considerados
    bloqueio por si só: a interface pública do Instagram exibe esses CTAs
    para visitantes deslogados mesmo quando os dados do perfil estão
    disponíveis. Só sinalizam login/challenge quando combinados com um
    indicador estrutural de login (URL de login/challenge ou texto de
    challenge/captcha/verificação de identidade).
    """
    low = (dom_text or "").lower()

    # Sinais estruturais inequívocos de login/challenge/bloqueio.
    structural_markers = [
        "challenge", "captcha", "verify your identity",
        "login_required", "please log in",
        "blocked", "you're blocked", "rate limit",
    ]
    if any(m in low for m in structural_markers):
        return True

    # URL da página aponta para login/challenge.
    if page_url and ("login" in page_url or "challenge" in page_url):
        return True

    # "sign up" (ou variações) é um CTA genérico da interface pública do
    # Instagram — aparece em perfis públicos normais. Só conta como bloqueio
    # quando acompanhado de um texto de challenge/login na mesma página.
    if "sign up" in low and any(m in low for m in structural_markers):
        return True

    return False


async def scrape_profile(username, proxy=None):
    browser_args = []
    if proxy:
        browser_args.append(f"--proxy-server={proxy}")

    browser = await uc.start(**browser_binary.start_kwargs(browser_args))
    try:
        page = await browser.get(f"https://www.instagram.com/{username}/")
        await asyncio.sleep(5)

        page_url = await page.evaluate("window.location.href")
        html = await page.get_content()
        dom_text = html or ""

        if _is_blocked(page_url, html, dom_text):
            raise BlockedPageError("page requires login/challenge")

        result = await page.evaluate(
            """
            (function() {
                try {
                    var data = window._sharedData;
                    if (data && data.entry_data && data.entry_data.ProfilePage && data.entry_data.ProfilePage[0]) {
                        var user = data.entry_data.ProfilePage[0].graphql.user;
                        return JSON.stringify({
                            user_id: user.id,
                            username: user.username,
                            full_name: user.full_name,
                            biography: user.biography,
                            followers_count: user.edge_followed_by.count,
                            following_count: user.edge_follow.count,
                            posts_count: user.edge_owner_to_timeline_media.count,
                            is_private: user.is_private,
                            is_verified: user.is_verified,
                            profile_pic_url: user.profile_pic_url_hd,
                            avatar_url: user.profile_pic_url_hd
                        });
                    }
                    return null;
                } catch(e) {
                    return JSON.stringify({error: e.message});
                }
            })()
            """
        )

        if result:
            parsed = json.loads(result)
            if isinstance(parsed, dict) and parsed.get("error"):
                # _sharedData presente mas inválido — tenta fallbacks abaixo.
                pass
            else:
                return parsed

        # Segunda fonte: scripts application/json contendo o objeto de usuário.
        json_result = await page.evaluate(
            """
            (function() {
                try {
                    var scripts = document.querySelectorAll('script[type="application/json"]');
                    for (var i = 0; i < scripts.length; i++) {
                        try {
                            var data = JSON.parse(scripts[i].textContent);
                            if (data && typeof data === 'object') {
                                var findUser = function(obj) {
                                    if (!obj || typeof obj !== 'object') return null;
                                    if (obj.username && (obj.edge_followed_by || obj.edge_owner_to_timeline_media)) return obj;
                                    for (var key in obj) {
                                        var found = findUser(obj[key]);
                                        if (found) return found;
                                    }
                                    return null;
                                };
                                var user = findUser(data);
                                if (user) {
                                    return JSON.stringify({
                                        user_id: user.id || user.id_str,
                                        username: user.username,
                                        full_name: user.full_name || user.name,
                                        biography: user.biography || user.bio || null,
                                        followers_count: user.edge_followed_by ? user.edge_followed_by.count : (user.followers_count !== undefined ? user.followers_count : null),
                                        following_count: user.edge_follow ? user.edge_follow.count : (user.following_count !== undefined ? user.following_count : null),
                                        posts_count: user.edge_owner_to_timeline_media ? user.edge_owner_to_timeline_media.count : null,
                                        is_private: user.is_private !== undefined ? user.is_private : (user.private !== undefined ? user.private : null),
                                        is_verified: user.is_verified !== undefined ? user.is_verified : (user.verified !== undefined ? user.verified : null),
                                        profile_pic_url: user.profile_pic_url_hd || user.profile_pic_url || null,
                                        avatar_url: user.profile_pic_url_hd || user.profile_pic_url || null
                                    });
                                }
                            }
                        } catch(e) {}
                    }
                    return null;
                } catch(e) {
                    return JSON.stringify({error: e.message});
                }
            })()
            """
        )
        if json_result:
            parsed = json.loads(json_result)
            if not (isinstance(parsed, dict) and parsed.get("error")):
                return parsed

        # Terceira fonte: metadados og para fallback parcial (perfil).
        meta_result = await page.evaluate(
            """
            (function() {
                try {
                    var ogTitle = document.querySelector('meta[property="og:title"]');
                    var ogDesc = document.querySelector('meta[property="og:description"]');
                    var ogImage = document.querySelector('meta[property="og:image"]');
                    if (ogTitle || ogDesc || ogImage) {
                        return JSON.stringify({
                            username: %(username)s,
                            full_name: ogTitle ? ogTitle.getAttribute('content') : null,
                            biography: ogDesc ? ogDesc.getAttribute('content') : null,
                            avatar_url: ogImage ? ogImage.getAttribute('content') : null,
                            fallback: true
                        });
                    }
                    return null;
                } catch(e) {
                    return JSON.stringify({error: e.message});
                }
            })()
            """ % {"username": json.dumps(username)}
        )
        if meta_result:
            parsed = json.loads(meta_result)
            if not (isinstance(parsed, dict) and parsed.get("error")):
                return parsed

        return None
    finally:
        await browser.stop()


async def scrape_posts(username, limit=12, proxy=None):
    browser_args = []
    if proxy:
        browser_args.append(f"--proxy-server={proxy}")

    browser = await uc.start(**browser_binary.start_kwargs(browser_args))
    try:
        page = await browser.get(f"https://www.instagram.com/{username}/")
        await asyncio.sleep(5)

        page_url = await page.evaluate("window.location.href")
        html = await page.get_content()
        dom_text = html or ""

        if _is_blocked(page_url, html, dom_text):
            raise BlockedPageError("page requires login/challenge")

        all_posts = []
        scroll_attempts = 0
        max_scrolls = (limit // 12) + 2

        def _posts_js():
            return (
                """
                (function() {
                    try {
                        var data = window._sharedData;
                        if (data && data.entry_data && data.entry_data.ProfilePage && data.entry_data.ProfilePage[0]) {
                            var media = data.entry_data.ProfilePage[0].graphql.user.edge_owner_to_timeline_media;
                            var posts = media.edges.map(function(edge) {
                                var node = edge.node;
                                return {
                                    platform_post_id: node.id,
                                    post_type: node.__typename,
                                    caption: node.edge_media_to_caption.edges.length > 0 ? node.edge_media_to_caption.edges[0].node.text : null,
                                    likes_count: node.edge_media_preview_like ? node.edge_media_preview_like.count : null,
                                    comments_count: node.edge_media_to_comment ? node.edge_media_to_comment.count : null,
                                    posted_at: node.taken_at_timestamp,
                                    thumbnail_url: node.thumbnail_src,
                                    is_video: node.is_video,
                                    video_url: node.is_video ? node.video_url : null,
                                    shortcode: node.shortcode
                                };
                            });
                            return JSON.stringify(posts);
                        }
                        return null;
                    } catch(e) {
                        return JSON.stringify({error: e.message});
                    }
                })()
                """
            )

        while len(all_posts) < limit and scroll_attempts < max_scrolls:
            result = await page.evaluate(_posts_js())

            posts = None
            if result:
                try:
                    parsed = json.loads(result)
                    if isinstance(parsed, list):
                        posts = parsed
                except Exception:
                    pass

            if not posts:
                # _sharedData ausente/inválido: tenta JSON embutido.
                json_fallback = await page.evaluate(
                    """
                    (function() {
                        try {
                            var scripts = document.querySelectorAll('script[type="application/json"]');
                            for (var i = 0; i < scripts.length; i++) {
                                try {
                                    var data = JSON.parse(scripts[i].textContent);
                                    if (data && typeof data === 'object') {
                                        var findMedia = function(obj) {
                                            if (!obj || typeof obj !== 'object') return null;
                                            if (obj.edge_owner_to_timeline_media && Array.isArray(obj.edge_owner_to_timeline_media.edges)) return obj;
                                            for (var key in obj) {
                                                var found = findMedia(obj[key]);
                                                if (found) return found;
                                            }
                                            return null;
                                        };
                                        var user = findMedia(data);
                                        if (user) {
                                            var media = user.edge_owner_to_timeline_media;
                                            var posts = media.edges.map(function(edge) {
                                                var node = edge.node;
                                                return {
                                                    platform_post_id: node.id,
                                                    post_type: node.__typename,
                                                    caption: node.edge_media_to_caption && node.edge_media_to_caption.edges.length > 0 ? node.edge_media_to_caption.edges[0].node.text : null,
                                                    likes_count: node.edge_media_preview_like ? node.edge_media_preview_like.count : null,
                                                    comments_count: node.edge_media_to_comment ? node.edge_media_to_comment.count : null,
                                                    posted_at: node.taken_at_timestamp,
                                                    thumbnail_url: node.thumbnail_src,
                                                    is_video: node.is_video,
                                                    video_url: node.is_video ? node.video_url : null,
                                                    shortcode: node.shortcode
                                                };
                                            });
                                            return JSON.stringify(posts);
                                        }
                                    }
                                } catch(e) {}
                            }
                            return null;
                        } catch(e) {
                            return JSON.stringify({error: e.message});
                        }
                    })()
                    """
                )
                if json_fallback:
                    try:
                        parsed_fb = json.loads(json_fallback)
                        if isinstance(parsed_fb, list):
                            posts = parsed_fb
                    except Exception:
                        pass

            if not posts:
                break

            for post in posts:
                if len(all_posts) >= limit:
                    break
                all_posts.append(post)

            await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            await asyncio.sleep(3)
            scroll_attempts += 1

        seen = set()
        unique_posts = []
        for post in all_posts:
            pid = post.get("platform_post_id")
            if pid and pid not in seen:
                seen.add(pid)
                unique_posts.append(post)

        return unique_posts
    finally:
        await browser.stop()


def main():
    parser = argparse.ArgumentParser(description="Instagram scraper via Nodriver")
    parser.add_argument("username", help="Instagram username")
    parser.add_argument("--mode", choices=["profile", "posts"], default="profile")
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--proxy", default=None)

    args = parser.parse_args()

    try:
        if args.mode == "profile":
            result = asyncio.run(scrape_profile(args.username, args.proxy))
        else:
            result = asyncio.run(scrape_posts(args.username, args.limit, args.proxy))

        if result:
            print(json.dumps(result))
        else:
            print(json.dumps({"error": "No data extracted"}))
            sys.exit(1)
    except BlockedPageError as e:
        print(json.dumps({"error": "blocked_page", "detail": str(e)}))
        sys.exit(3)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
