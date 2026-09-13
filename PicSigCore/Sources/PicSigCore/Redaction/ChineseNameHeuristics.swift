import Foundation

/// Decides how much a two-to-four character token *looks like* a Chinese
/// personal name, without any label next to it.
///
/// A surname-led token on its own is not evidence enough: a third of everyday
/// words start with a character that is also a surname ("全部", "时间", "余额").
/// What separates "王小明" from "高级" is the rest of the token — given names are
/// drawn from a fairly small set of characters, whereas words end in nouns and
/// grammatical particles. The scorer rewards a common surname and given-name
/// characters, penalises word-like endings, and rejects a list of frequent words
/// outright. The result is an adjustment added to the rule's base confidence.
public enum ChineseNameHeuristics {
    /// The hundred or so surnames that cover most of the population. A token
    /// starting with one of these is far more likely to be a name than one
    /// starting with, say, 巢 or 訾.
    public static let commonSurnames: Set<Character> = Set(
        "王李张刘陈杨黄赵吴周徐孙马朱胡郭何林罗高郑梁谢宋唐许邓韩冯曹彭曾萧田董潘袁蔡蒋余于杜叶程魏苏吕丁任卢姚沈钟姜崔谭陆范汪廖石金韦贾夏付方邹熊白孟秦邱侯江尹薛闵段雷龙黎史陶贺顾毛郝龚邵万钱严覃武戴莫孔向汤常温康施文牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧耿关兰焦俞左柳甘祝包宁尚符舒阮柯纪梅童凌毕单季裴霍涂成苗谷盛曲翁冉骆蓝路游辛"
    )

    /// Characters that make up the bulk of given names.
    public static let givenNameCharacters: Set<Character> = Set(
        "伟芳娜敏静丽强磊军洋勇艳杰娟涛明超秀霞平刚桂英华文玉兰红建国志春海云龄晓小雨子思欣怡宇浩轩涵佳梓泽一诺可馨妍晴若语桐沐悦宁然辰昊哲睿博鑫鹏飞龙燕凤莉琳琴珍珊瑶瑾璇琪琦婷婉娇嫣慧智聪颖秋冬月星辉光亮阳旭东正义仁德贤良善美丹青彤霏菲薇蕾蓉莎茜菁芸芹芬茹荷莲梅竹松柏梦婕姗韵音诗书画玲珑玮珂珏翠碧瑜璐瑞祥福禄寿喜财富贵荣昌盛兴旺达立业家邦民生康健乐欢恩慈爱忆恒永久远大元亨利贞坤天山川河江湖洲波清澄洁净纯真诚淑惠雅芊柔楠森林木栋梁桦楷铭锐钧铮锦钰鸣翔翎羽翰凌冰雪霜露霄昕曦晗晨曙晟昭晖皓骏弘毅坚勤敬学修齐治定宏广深厚峰岳岩钢铁银珠宝环佩凯胜捷威武雄豪帅将士儒圣婧妙妮娅娥婵媛三四五六七八九十百千万世代传承先后启发展开拓创新颐养和鸣祺禧祯祚圭璧玺璋庭轼辂轲绮绫绣绢缤纾芷芮茉苓荃蓁菡萱蕊薏藜苑莘荔荪莞菀蔷蕙芙芃茵荞葵蒂蔓瑭琤琬琇琍瑛瑗璎璟瓒珈珮珞珣珲琚"
    )

    /// Characters that end ordinary words far more often than names: nouns,
    /// suffixes, particles, units of place.
    public static let wordLikeEndings: Set<Character> = Set(
        "部间额务闭看册案级用果园节线辆省市区县店街路号楼室单的了是在有和与或及不就都也要到会能可以这那个们什么吗呢吧啊上下里外前后左右内边面点次回条件项类型式度量数据息容置统版录史消通知醒址话箱户码付订品价格费款折扣券票证同议则助页索车目本机头全"
    )

    /// Frequent words that pass the pattern and the character checks anyway.
    public static let stopWords: Set<String> = [
        "全部", "全屏", "全选", "全球", "全新", "时间", "时候", "时刻", "余额", "余下", "任务", "任意", "任何",
        "关闭", "关注", "关于", "关系", "查看", "查询", "相册", "相机", "相关", "相同", "安全", "安装", "安静",
        "明天", "明白", "明细", "明显", "今天", "昨天", "白天", "高级", "高度", "高速", "金额", "金融", "方案",
        "方式", "方向", "方法", "成功", "成为", "成员", "常用", "常见", "石头", "水果", "水平", "花园", "花费",
        "章节", "路线", "路径", "车辆", "车票", "和平", "向前", "向上", "向下", "云南", "云端", "江苏", "山东",
        "山西", "河南", "河北", "湖南", "湖北", "华为", "华南", "华北", "华东", "文件", "文字", "文档", "文章",
        "平台", "平均", "平时", "谷歌", "苹果", "米饭", "空间", "空白", "印象", "印刷", "宁静", "从前", "从头",
        "于是", "史上", "程序", "程度", "包括", "包裹", "单位", "单价", "单号", "宣传", "应用", "应该", "解决",
        "解释", "宗旨", "干净", "干部", "管理", "莫非", "房间", "房子", "卢比", "支付", "支持", "柯基", "万一",
        "万元", "田地", "夏天", "夏季", "高手", "骆驼", "邱比", "徐徐", "钟表", "林间", "梅雨", "童年", "危险",
        "路口", "季度", "季节", "席位", "强制", "麻烦", "蓝牙", "蓝色", "阮咸", "杜绝", "梁柱", "董事", "祝福",
        "项目", "屈服", "舒服", "纪录", "熊猫", "庞大", "茅台", "宋体", "谈话", "戴上", "成本", "伏特", "计划",
        "计算", "臧否", "明年", "贝壳", "米色", "狄仁", "毛病", "汪汪", "湛蓝", "邵阳", "姚明", "尹始", "穆斯",
        "和谐", "黄色", "平安", "孟子", "顾客", "卜卦", "元旦", "余数", "伍元", "康复", "齐全", "皮肤", "傅里",
        "时段", "于此", "乐观", "常规", "安卓", "邬县", "郝然", "毕业", "殷切", "汤匙", "倪端", "贺卡", "雷电",
        "薛定", "罗盘", "唐朝", "柳树", "袁隆", "任由", "俞言", "方位", "花朵", "凤凰", "苗头", "马上", "昌盛",
        "韦编", "鲁莽", "郎朗", "彭湃", "范围", "奚落", "葛藤", "潘多", "苏打", "云雾", "章程", "窦娥", "水分",
        "柏树", "喻示", "邹忌", "谢谢", "戚戚", "姜黄", "陶瓷", "魏晋", "金牌", "华丽", "严格", "曹操", "孔子",
        "张开", "施工", "吕布", "何时", "许多", "尤其", "秦朝", "朱红", "杨柳", "韩国", "沈阳", "蒋介", "卫生",
        "褚遂", "陈述", "冯唐", "王者", "郑重", "吴语", "周末", "李子", "孙子", "钱包", "赵国",
        "首页", "收藏", "购物", "订单", "付款", "确认", "取消", "完成", "返回", "分享", "编辑", "删除", "保存"
    ]

    /// How much to add to a name rule's base confidence for this token.
    ///
    /// Roughly −0.5 for a known word, up to about +0.3 for a textbook name.
    public static func confidenceAdjustment(for token: String) -> Double {
        let characters = Array(token)
        guard characters.count >= 2, characters.count <= 4 else { return -0.3 }
        if stopWords.contains(token) { return -0.5 }

        let surnameLength = twoCharacterSurnameLength(characters)
        let given = Array(characters.dropFirst(surnameLength))
        guard !given.isEmpty, given.count <= 2 else { return -0.3 }

        var score = 0.0
        if surnameLength == 2 {
            score += 0.2
        } else if commonSurnames.contains(characters[0]) {
            score += 0.15
        } else {
            score += 0.02
        }

        let nameLike = given.filter { givenNameCharacters.contains($0) }.count
        if nameLike == given.count {
            score += 0.1
        } else if nameLike > 0 {
            score += 0.05
        }

        let wordLike = given.filter { wordLikeEndings.contains($0) }.count
        score -= 0.15 * Double(wordLike)

        // Three characters is the classic shape; two-character words are far
        // more common than two-character names.
        if given.count == 2 { score += 0.05 }

        // A doubled given character ("丽丽", "婷婷") is a nickname pattern.
        if given.count == 2, given[0] == given[1], givenNameCharacters.contains(given[0]) { score += 0.05 }

        return max(-0.5, min(0.3, score))
    }

    /// Length of the surname at the start of the token: 2 for a compound
    /// surname the list knows, otherwise 1.
    private static func twoCharacterSurnameLength(_ characters: [Character]) -> Int {
        guard characters.count >= 3 else { return 1 }
        let head = String(characters[0...1])
        return BuiltinRules.surnames.contains(head) && head.count == 2 ? 2 : 1
    }
}
