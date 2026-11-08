extension AgentSkillsInstaller {
    /// SHA-256 of every SKILL.md text (content and final newline) Nirux
    /// shipped before it recorded the texts it writes, by skill name. Copies
    /// those builds installed have no record; these tell them from copies the
    /// user edited. Frozen: every later text is recorded in the state
    /// directory by the app that ships it, at launch (see `recordTexts`).
    static let textsShippedBeforeRecords: [String: Set<String>] = [
        "nirux-draft": [
            "0d0907315019aa9d414c07ad66e0bec9707cb3dc5822a7dd0a85fec17eb46e6a",
            "4a0ff16b6170ef3955cf9e13975b79c95c37d199dfd662c0b6a08ceacb9c43c7"
        ],
        "nirux-second-opinion": [
            "75e83998d801899bc1f9ee171edb0c7764da4f3d6ab3ccbbf447fbc119944cdb",
            "a04206221816e01ce9cb11d89dcd975993318bc7db9e3a2901a7a1ca65e29d5e"
        ],
        "nirux-show-code": [
            "26a6351cb228b96835aa276b7c84223b0c77f1a2996f43baad7597be430879d6",
            "4855b4264ebd941edc02bd4c4c7dc1bfa3a0e0f29dc6f0493d290cc521dc61a4",
            "876ab42f2b9191597250d7ad2bf920862e05d4f5ca384b76dd5ac0ccfb9f621e",
            "8846f5c52a669c283438da285ccc6b7c00e9d66b0d4cde69815b974bce39697a",
            "a7c356d2983b5a63b4b2b8fe2f11fb234e30aaef783fbad5bb64bea07a91499d"
        ],
        "nirux-worktree": [
            "0a331feee5af08e1108edb7832cbc0430b223d59dd61b55c1a31ff55932fbced",
            "14c1e9fdc7da0f26f723a55c6fb24eb8ae0b9342dc9cd4910eec1ab5f0b21778",
            "238edbe53c07369258c507630b4730743886440b0431164d469d48efb31ee397",
            "3808103f1b02d22d7e2278fa405149e4ec343cb21f95336b4376be154b064de6",
            "45d71a390b49cfa68ad4ef114eae9202a97f1b8250e99a375fe4f7e6403ccc27",
            "539a429e49945f69a342fb352db6a847dc6a375237bb16a6fcddc391411ed013",
            "78af7a4037c85074310d4224160ca885f54290bb8f5424f6401b86765b798c37",
            "989c195e8d82c064419e1f002e871fe9d127639e4028d703929357297c9eff3d",
            "98a95b3acbd0ff6b4268b51c1bd12b38f8364eb02d23086220de21045878efc2",
            "b8602615560af9cdd4a903908240204b423b9a7aa5d862fe02a634372ab1c54e",
            "be05a9a43d0d1eeb96339a55cf2d60f49cc9bf48d59d85d88ec1ce85136baa19",
            "dbfec6afd70ad53afceea826b9c66c32958d6deed5332615a19a5100c46d91b5",
            "e49d4341da13b55da00c204cf1499751d3ae0e8bf91c19f8a8d70211d98d3ad1"
        ]
    ]
}
