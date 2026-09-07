/*
 * Copyright (c) 2010-2017 OTClient <https://github.com/edubart/otclient>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#include "uiitem.h"
#include "spritemanager.h"
#include "game.h"
#include <framework/otml/otml.h>
#include <framework/graphics/graphics.h>
#include <framework/graphics/fontmanager.h>
#include <cmath>

// Server item id for "a dormant waker" (data/items/items.xml) -- the
// permanent tool used to reveal Dormant items. Always gets the same sparkle
// treatment as a Dormant item, independent of tier, since the Waker itself
// is never Dormant.
static constexpr int IDENTIFYING_LENS_ID = 39241;

UIItem::UIItem()
{
    m_draggable = true;
    m_color = Color(231, 231, 231);
    m_itemColor = Color::white;
    m_lastDecayUpdate = 0;
    m_decayColor = Color(127, 255, 212);
    m_decayPausedColor = Color(222, 109, 109);
}

void UIItem::drawSelf(Fw::DrawPane drawPane)
{
    if(drawPane != Fw::ForegroundPane)
        return;
    // draw style components in order
    if(m_backgroundColor.aF() > Fw::MIN_ALPHA) {
        Rect backgroundDestRect = m_rect;
        backgroundDestRect.expand(-m_borderWidth.top, -m_borderWidth.right, -m_borderWidth.bottom, -m_borderWidth.left);
        drawBackground(m_rect);
    }

    drawImage(m_rect);

    if(m_itemVisible && m_item) {
        Rect drawRect = getPaddingRect();

        int exactSize = std::max<int>(g_sprites.spriteSize(), m_item->getExactSize());
        if(exactSize == 0)
            return;

        m_item->setColor(m_itemColor);
        m_item->draw(drawRect);

        // Rarity tier corner marker -- the server repurposes the native
        // per-item Tier byte (normally the Forge tier system, which this
        // fork keeps permanently disabled) to carry a custom rarity tier
        // instead: 1=Scarce/2=Adept/3=Superior/4=Prime, 5=Dormant (rolled
        // but not yet identified -- see RarityStats.DORMANT_TIER on the
        // server). Small filled triangle wedge in the top-left corner so it
        // never collides with the stack count/item id/decay countdown,
        // which all render bottom-right below. Colors match the
        // loot-channel text coloring exactly (data/lib/core/container.lua
        // on the server).
        if (m_item->getTier() >= 1 && m_item->getTier() <= 4) {
            Color markerColor;
            switch (m_item->getTier()) {
                case 1: markerColor = Color(159, 184, 106); break; // Scarce   - moss green
                case 2: markerColor = Color(124, 195, 228); break; // Adept    - blue
                case 3: markerColor = Color(185, 140, 240); break; // Superior - purple
                case 4: markerColor = Color(242,  85,  75); break; // Prime    - crimson
            }
            const int markerSize = 8;
            g_drawQueue->addFilledTriangle(
                drawRect.topLeft(),
                drawRect.topLeft() + Point(markerSize, 0),
                drawRect.topLeft() + Point(0, markerSize),
                markerColor
            );
        } else if (m_item->getTier() == 5 || m_item->getId() == IDENTIFYING_LENS_ID) {
            // Dormant items AND the Dormant Waker itself (item 39241 -- a
            // permanent tool, not tier-based, so it needs its own id check,
            // via getId()/m_clientId rather than getServerId() -- see
            // item.cpp's matching ground-draw block for why getServerId()
            // never works in this client) get the exact same sparkle
            // treatment/color, on purpose -- the Waker is themed to look
            // like it's carrying the same dormant energy it awakens. Small
            // 4-point star sparkle (two thin overlapping diamonds, one N-S
            // and one E-W, each built from two triangles) scattered over the
            // item, instead of a flat wash or plain squares -- reads as an
            // actual twinkle. Each sparkle blinks on its own phase-shifted
            // sine wave, and gets a tiny bright core for extra glint. Fixed
            // relative positions (not random per-frame) so they don't
            // visibly jump around.
            static const float sparklePositions[][2] = {
                {0.22f, 0.28f}, {0.72f, 0.18f}, {0.50f, 0.55f}, {0.28f, 0.78f}, {0.78f, 0.68f}
            };
            const double t = static_cast<double>(stdext::millis()) / 300.0;
            const int armLength = std::max(3, drawRect.width() / 7);
            const int armWidth = std::max(1, armLength / 4);
            for (int i = 0; i < 5; ++i) {
                const double pulse = (std::sin(t + i * 1.31) + 1.0) / 2.0; // 0..1, phase-shifted per sparkle
                const int sparkleAlpha = static_cast<int>(pulse * 230);
                const Point center = drawRect.topLeft() + Point(
                    static_cast<int>(sparklePositions[i][0] * drawRect.width()),
                    static_cast<int>(sparklePositions[i][1] * drawRect.height())
                );
                const Color sparkleColor = Color(255, 195, 100, sparkleAlpha);
                const Color coreColor = Color(255, 240, 210, sparkleAlpha);

                g_drawQueue->addFilledTriangle(Point(center.x, center.y - armLength), Point(center.x + armWidth, center.y), Point(center.x, center.y + armLength), sparkleColor);
                g_drawQueue->addFilledTriangle(Point(center.x, center.y - armLength), Point(center.x - armWidth, center.y), Point(center.x, center.y + armLength), sparkleColor);
                g_drawQueue->addFilledTriangle(Point(center.x - armLength, center.y), Point(center.x, center.y - armWidth), Point(center.x + armLength, center.y), sparkleColor);
                g_drawQueue->addFilledTriangle(Point(center.x - armLength, center.y), Point(center.x, center.y + armWidth), Point(center.x + armLength, center.y), sparkleColor);

                const int coreSize = std::max(2, armWidth);
                g_drawQueue->addFilledRect(Rect(center - Point(coreSize / 2, coreSize / 2), coreSize, coreSize), coreColor);
            }
        }

        if(m_font && m_showCount && (m_showCountAlways || (m_item->isStackable() || m_item->isChargeable() || m_item->isQuiver()) && m_item->getCountOrSubType() > 1)) {
            g_drawQueue->addText(m_font, m_countText, Rect(drawRect.topLeft(), drawRect.bottomRight() - Point(3, 0)), Fw::AlignBottomRight, m_color);
        }

        if (m_showId) {
            g_drawQueue->addText(m_font, std::to_string(m_item->getServerId()), drawRect, Fw::AlignBottomRight, m_color);
        }

        if (g_game.getFeature(Otc::GameDisplayItemDuration)) {
            if (m_item->getDurationTime() > 0) {
                auto isPaused = m_item->isDurationPaused();
                if (m_lastDecayUpdate + 1000 < stdext::millis()) {
                    uint64 duration = m_item->getDurationTime() - (isPaused ? m_item->getDurationTimePaused() : stdext::unixtimeMs());
                    m_decayText = stdext::secondsToDuration(duration / 1000);
                    m_lastDecayUpdate = stdext::millis();
                }
                g_drawQueue->addText(m_font, m_decayText, drawRect, Fw::AlignBottomRight, isPaused ? m_decayPausedColor : m_decayColor);
            }
        }
    }

    drawBorder(m_rect);
    drawIcon(m_rect);
    drawText(m_rect);
}

void UIItem::setItemId(int id)
{
    if (!m_item && id != 0)
        m_item = Item::create(id);
    else {
        // remove item
        if (id == 0)
            m_item = nullptr;
        else
            m_item->setId(id);
    }

    if (m_item)
        m_item->setShader(m_shader);

    m_lastDecayUpdate = 0;

    callLuaField("onItemChange");
}

void UIItem::setItemCount(int count)
{
    if (m_item) {
        m_item->setCount(count);
        callLuaField("onItemChange");
        cacheCountText();
    }
}

void UIItem::setItemSubType(int subType)
{
    if (m_item) {
        m_item->setSubType(subType);
        callLuaField("onItemChange");
    }
}

void UIItem::setItem(const ItemPtr& item)
{
    m_item = item;
    if (m_item) {
        m_item->setShader(m_shader);

        m_lastDecayUpdate = 0;

        cacheCountText();
        callLuaField("onItemChange");
    }
}

void UIItem::setItemShader(const std::string& str)
{
    m_shader = str;

    if (m_item) {
        m_item->setShader(m_shader);
        callLuaField("onItemChange");
    }
}

void UIItem::onStyleApply(const std::string& styleName, const OTMLNodePtr& styleNode)
{
    UIWidget::onStyleApply(styleName, styleNode);

    for(const OTMLNodePtr& node : styleNode->children()) {
        if(node->tag() == "item-id")
            setItemId(node->value<int>());
        else if(node->tag() == "item-count")
            setItemCount(node->value<int>());
        else if(node->tag() == "item-visible")
            setItemVisible(node->value<bool>());
        else if(node->tag() == "virtual")
            setVirtual(node->value<bool>());
        else if(node->tag() == "show-id")
            m_showId = node->value<bool>();
        else if(node->tag() == "shader")
            setItemShader(node->value());
        else if(node->tag() == "item-color")
            setItemColor(node->value<Color>());
        else if(node->tag() == "item-always-show-count")
            setShowCountAlways(node->value<bool>());
    }
}

void UIItem::cacheCountText()
{
    int count = m_item->getCountOrSubType();
    if (!g_game.getFeature(Otc::GameCountU16) || count < 1000) {
        m_countText = std::to_string(count);
        return;
    }

    m_countText = stdext::format("%.0fk", count / 1000.0);
}
