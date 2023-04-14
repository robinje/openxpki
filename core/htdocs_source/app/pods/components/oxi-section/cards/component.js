import Component from '@glimmer/component'
import Button from 'openxpki/data/button'

/**
 * Draws cards.
 *
 * @param { hash } def - card section definition
 * ```javascript
 * {
 *      label: 'Realms',
 *      description: 'Please choose a realm',
 *      vertical: true, // optional, default: false
 *      cards: [
 *          {
 *              label: 'Demo-CA',
 *              description: "The demo CA",
 *              footer: 'Auto-Login',
 *              image: 'data:image/webp;base64,UklGRsIdAAB...',
 *              href: '/demo-ca/',
 *          },
 *          {
 *              ...
 *              page: 'workflow!one',
 *          },
 *          ...
 *      ],
 * }
 * ```
 * @class OxiSection::Cards
 * @extends Component
 */
export default class OxiSectionCardsComponent extends Component {
    get cards() {
        let cards = this.args.def.cards || []
        // inject _button property
        cards.forEach(c => c._button = Button.fromHash(c))
        return cards
    }
}
